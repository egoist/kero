import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SSHCredential {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

struct SSHConnectionConfiguration {
    let host: SSHHost
    let credential: SSHCredential
    let term: String
    let environment: [String: String]
    let initialSize: SSHWindowSize
}

struct SSHWindowSize {
    let columns: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

enum SSHConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

struct SSHCommandResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let exitStatus: Int

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

enum SSHCommandError: LocalizedError {
    case notConnected
    case requestRejected
    case terminated(signal: String)
    case channelClosed
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Connect to the server before loading project information."
        case .requestRejected:
            "The SSH server rejected the remote command."
        case .terminated(let signal):
            "The remote command was terminated by \(signal)."
        case .channelClosed:
            "The remote command channel closed before returning a result."
        case .outputTooLarge:
            "The remote command returned too much data."
        }
    }
}

enum SSHClientError: LocalizedError {
    case authenticationMethodUnavailable
    case authenticationRejected
    case connectionTimedOut
    case invalidChannelType
    case hostKeyRejected

    var errorDescription: String? {
        switch self {
        case .authenticationMethodUnavailable:
            "The server does not support the selected authentication method."
        case .authenticationRejected:
            "Authentication failed. Check the username and password or SSH key."
        case .connectionTimedOut:
            "The SSH handshake timed out. Check the server address, network access, and authentication settings."
        case .invalidChannelType:
            "The SSH server opened an unsupported channel."
        case .hostKeyRejected:
            "The server identity was not trusted."
        }
    }
}

typealias SSHHostKeyValidator = (
    _ openSSHKey: String,
    _ completion: @escaping (Bool) -> Void
) -> Void

private final class SSHUserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let credential: SSHCredential
    private var offeredCredential = false

    init(username: String, credential: SSHCredential) {
        self.username = username
        self.credential = credential
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offeredCredential else {
            nextChallengePromise.fail(SSHClientError.authenticationRejected)
            return
        }
        offeredCredential = true

        switch credential {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(SSHClientError.authenticationMethodUnavailable)
                return
            }
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .password(.init(password: password))
                )
            )
        case .privateKey(let privateKey):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(SSHClientError.authenticationMethodUnavailable)
                return
            }
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: privateKey))
                )
            )
        }
    }
}

private final class SSHServerAuthenticationDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let validator: SSHHostKeyValidator
    private let onValidationStarted: () -> Void
    private let onValidationCompleted: () -> Void

    init(
        validator: @escaping SSHHostKeyValidator,
        onValidationStarted: @escaping () -> Void,
        onValidationCompleted: @escaping () -> Void
    ) {
        self.validator = validator
        self.onValidationStarted = onValidationStarted
        self.onValidationCompleted = onValidationCompleted
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        onValidationStarted()
        validator(String(openSSHPublicKey: hostKey)) { isTrusted in
            if isTrusted {
                self.onValidationCompleted()
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHClientError.hostKeyRejected)
            }
        }
    }
}

private final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class SSHCloseHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }
}

private final class TerminalOutputPump {
    private static let maximumPendingBytes = 8 * 1_024 * 1_024
    private static let drainSize = 65_536
    private static let truncationNotice = Array(
        "\r\n[Kero] Terminal output was truncated to protect app memory.\r\n".utf8
    )

    private weak var terminalView: KeroTerminalView?
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var readIndex = 0
    private var drainScheduled = false
    private var outputWasTruncated = false

    init(terminalView: KeroTerminalView) {
        self.terminalView = terminalView
    }

    func enqueue(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }
        lock.lock()
        pending.append(contentsOf: bytes)
        let readableCount = pending.count - readIndex
        if readableCount > Self.maximumPendingBytes {
            readIndex += readableCount - Self.maximumPendingBytes
            outputWasTruncated = true
        }
        compactBufferIfNeeded()
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                self?.drain()
            }
        }
    }

    @MainActor
    private func drain() {
        var bytes: [UInt8]
        let hasMore: Bool

        lock.lock()
        let readableCount = pending.count - readIndex
        let count = min(readableCount, Self.drainSize)
        bytes = Array(pending[readIndex..<(readIndex + count)])
        readIndex += count
        if outputWasTruncated {
            bytes.insert(contentsOf: Self.truncationNotice, at: 0)
            outputWasTruncated = false
        }
        hasMore = readIndex < pending.count
        drainScheduled = hasMore
        compactBufferIfNeeded()
        lock.unlock()

        if !bytes.isEmpty {
            terminalView?.receive(Data(bytes))
        }
        if hasMore {
            DispatchQueue.main.async { [weak self] in
                self?.drain()
            }
        }
    }

    private func compactBufferIfNeeded() {
        guard readIndex > 0 else {
            return
        }
        if readIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= 1_024 * 1_024 {
            pending.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

private final class SSHShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let outputPump: TerminalOutputPump
    private let term: String
    private let environment: [String: String]
    private let initialSize: SSHWindowSize
    private let startupCommand: String?
    private let onReady: () -> Void
    private let onExit: (String) -> Void

    init(
        outputPump: TerminalOutputPump,
        term: String,
        environment: [String: String],
        initialSize: SSHWindowSize,
        startupCommand: String?,
        onReady: @escaping () -> Void,
        onExit: @escaping (String) -> Void
    ) {
        self.outputPump = outputPump
        self.term = term
        self.environment = environment
        self.initialSize = initialSize
        self.startupCommand = startupCommand
        self.onReady = onReady
        self.onExit = onExit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(
            ChannelOptions.allowRemoteHalfClosure,
            value: true
        ).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: initialSize.columns,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: initialSize.pixelWidth,
            terminalPixelHeight: initialSize.pixelHeight,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        for (name, value) in environment {
            let request = SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: name,
                value: value
            )
            context.triggerUserOutboundEvent(request, promise: nil)
        }

        let shellPromise = context.eventLoop.makePromise(of: Void.self)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ShellRequest(wantReply: true),
            promise: shellPromise
        )
        shellPromise.futureResult.whenComplete { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success:
                self.onReady()
                if let startupCommand {
                    var buffer = context.channel.allocator.buffer(
                        capacity: startupCommand.utf8.count + 1
                    )
                    buffer.writeString(startupCommand)
                    buffer.writeInteger(UInt8(13))
                    context.channel.writeAndFlush(
                        SSHChannelData(type: .channel, data: .byteBuffer(buffer)),
                        promise: nil
                    )
                }
            case .failure(let error):
                context.fireErrorCaught(error)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }
        outputPump.enqueue(bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            onExit("Session exited with status \(status.exitStatus).")
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            onExit("Session closed: \(signal.signalName).")
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class SSHExecChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private static let maximumOutputBytes = 4 * 1_024 * 1_024

    private let command: String
    private var stdout = Data()
    private var stderr = Data()
    private var completion: ((Result<SSHCommandResult, Error>) -> Void)?

    init(
        command: String,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        self.command = command
        self.completion = completion
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(
            ChannelOptions.allowRemoteHalfClosure,
            value: true
        ).whenFailure { [weak self] error in
            self?.finish(.failure(error), context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let requestPromise = context.eventLoop.makePromise(of: Void.self)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(
                command: command,
                wantReply: true
            ),
            promise: requestPromise
        )
        requestPromise.futureResult.whenFailure { [weak self] _ in
            self?.finish(
                .failure(SSHCommandError.requestRejected),
                context: context
            )
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        switch payload.type {
        case .channel:
            stdout.append(contentsOf: bytes)
        case .stdErr:
            stderr.append(contentsOf: bytes)
        default:
            return
        }

        if stdout.count + stderr.count > Self.maximumOutputBytes {
            finish(.failure(SSHCommandError.outputTooLarge), context: context)
        }
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            finish(
                .success(
                    SSHCommandResult(
                        stdout: stdout,
                        stderr: stderr,
                        exitStatus: status.exitStatus
                    )
                ),
                context: context
            )
        case let signal as SSHChannelRequestEvent.ExitSignal:
            finish(
                .failure(
                    SSHCommandError.terminated(signal: signal.signalName)
                ),
                context: context
            )
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(SSHCommandError.channelClosed), context: context)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error), context: context)
    }

    private func finish(
        _ result: Result<SSHCommandResult, Error>,
        context: ChannelHandlerContext
    ) {
        guard let completion else {
            return
        }
        self.completion = nil
        DispatchQueue.main.async {
            completion(result)
        }
        context.close(promise: nil)
    }
}

final class SSHConnection {
    private enum TerminationReason {
        case user
        case failure
        case remote
    }

    private let configuration: SSHConnectionConfiguration
    private let validateHostKey: SSHHostKeyValidator
    private let onStateChange: (SSHConnectionState) -> Void
    private let outputPump: TerminalOutputPump
    private let connectionTimeout: TimeAmount

    private let stateLock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sessionChannel: Channel?
    private var connectionTimeoutTask: Scheduled<Void>?
    private var terminationReason: TerminationReason?

    init(
        terminalView: KeroTerminalView,
        configuration: SSHConnectionConfiguration,
        validateHostKey: @escaping SSHHostKeyValidator,
        connectionTimeout: TimeAmount = .seconds(30),
        onStateChange: @escaping (SSHConnectionState) -> Void
    ) {
        self.configuration = configuration
        self.validateHostKey = validateHostKey
        self.connectionTimeout = connectionTimeout
        self.onStateChange = onStateChange
        self.outputPump = TerminalOutputPump(terminalView: terminalView)
    }

    func connect() {
        notify(.connecting)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        stateLock.lock()
        self.group = group
        stateLock.unlock()
        armConnectionTimeout()
        let host = configuration.host
        let userAuth = SSHUserAuthenticationDelegate(
            username: host.username,
            credential: configuration.credential
        )
        let serverAuth = SSHServerAuthenticationDelegate(
            validator: validateHostKey,
            onValidationStarted: { [weak self] in
                self?.pauseConnectionTimeout()
            },
            onValidationCompleted: { [weak self] in
                self?.armConnectionTimeout()
            }
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else {
                        return
                    }
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: userAuth,
                                serverAuthDelegate: serverAuth
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler { [weak self] error in
                            self?.handleFailure(error)
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        SSHCloseHandler { [weak self] in
                            self?.handleTransportClosed()
                        }
                    )
                }
            }
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: 1
            )
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY),
                value: 1
            )
            .connectTimeout(.seconds(15))

        bootstrap.connect(host: host.hostname, port: host.port).whenComplete {
            [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure(let error):
                self.handleFailure(error)
            case .success(let channel):
                guard self.installTransportChannel(channel) else {
                    channel.close(promise: nil)
                    return
                }
                self.createSessionChannel(on: channel)
            }
        }
    }

    func send(_ data: Data) {
        guard let sessionChannel = currentSessionChannel() else {
            return
        }
        sessionChannel.eventLoop.execute {
            var buffer = sessionChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            sessionChannel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer)),
                promise: nil
            )
        }
    }

    func resize(_ size: SSHWindowSize) {
        guard size.columns > 0,
              size.rows > 0,
              let sessionChannel = currentSessionChannel() else {
            return
        }
        sessionChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: size.columns,
                terminalRowHeight: size.rows,
                terminalPixelWidth: size.pixelWidth,
                terminalPixelHeight: size.pixelHeight
            )
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    func execute(
        command: String,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        guard !command.isEmpty,
              let channel = currentTransportChannel() else {
            DispatchQueue.main.async {
                completion(.failure(SSHCommandError.notConnected))
            }
            return
        }

        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete {
            result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(
                    promise,
                    channelType: .session
                ) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(
                            SSHClientError.invalidChannelType
                        )
                    }
                    return childChannel.pipeline.addHandler(
                        SSHExecChannelHandler(
                            command: command,
                            completion: completion
                        )
                    )
                }
                promise.futureResult.whenFailure { error in
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func disconnect() {
        guard beginTermination(.user) else {
            return
        }
        notify(.disconnected)
        closeTransport()
    }

    private func createSessionChannel(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete {
            [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure(let error):
                self.handleFailure(error)
            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(
                    promise,
                    channelType: .session
                ) { [weak self] childChannel, channelType in
                    guard let self, channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(
                            SSHClientError.invalidChannelType
                        )
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        let handler = SSHShellChannelHandler(
                            outputPump: self.outputPump,
                            term: self.configuration.term,
                            environment: self.configuration.environment,
                            initialSize: self.configuration.initialSize,
                            startupCommand: self.configuration.host.startsTmux
                                ? "tmux new-session -A -s kero"
                                : nil,
                            onReady: { [weak self] in
                                self?.handleReady()
                            },
                            onExit: { [weak self] message in
                                self?.handleRemoteExit(message)
                            }
                        )
                        try childChannel.pipeline.syncOperations.addHandler(handler)
                        try childChannel.pipeline.syncOperations.addHandler(
                            SSHErrorHandler { [weak self] error in
                                self?.handleFailure(error)
                            }
                        )
                        try childChannel.pipeline.syncOperations.addHandler(
                            SSHCloseHandler { [weak self] in
                                self?.handleRemoteExit(nil)
                            }
                        )
                    }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else {
                        return
                    }
                    switch result {
                    case .failure(let error):
                        self.handleFailure(error)
                    case .success(let sessionChannel):
                        guard self.installSessionChannel(sessionChannel) else {
                            sessionChannel.close(promise: nil)
                            return
                        }
                        self.sendInitialResize()
                    }
                }
            }
        }
    }

    private func sendInitialResize() {
        resize(configuration.initialSize)
    }

    private func handleFailure(_ error: Error) {
        guard beginTermination(.failure) else {
            return
        }
        notify(.failed(error.localizedDescription))
        closeTransport()
    }

    private func handleReady() {
        pauseConnectionTimeout()
        stateLock.lock()
        let shouldNotify = terminationReason == nil
        stateLock.unlock()
        if shouldNotify {
            notify(.connected)
        }
    }

    private func handleRemoteExit(_ message: String?) {
        if let message {
            outputPump.enqueue(
                Array("\r\n[Kero] \(message)\r\n".utf8)
            )
        }
        guard beginTermination(.remote) else {
            return
        }
        notify(.disconnected)
        closeTransport()
    }

    private func handleTransportClosed() {
        if beginTermination(.failure) {
            notify(.failed("The SSH connection closed."))
        }
        shutdownGroup()
    }

    private func beginTermination(_ reason: TerminationReason) -> Bool {
        stateLock.lock()
        guard terminationReason == nil else {
            stateLock.unlock()
            return false
        }
        terminationReason = reason
        let timeoutTask = connectionTimeoutTask
        connectionTimeoutTask = nil
        stateLock.unlock()
        timeoutTask?.cancel()
        return true
    }

    private func armConnectionTimeout() {
        stateLock.lock()
        guard terminationReason == nil, let group else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let task = group.next().scheduleTask(in: connectionTimeout) {
            [weak self] in
            guard let self else {
                return
            }
            self.handleFailure(SSHClientError.connectionTimedOut)
        }

        stateLock.lock()
        guard terminationReason == nil else {
            stateLock.unlock()
            task.cancel()
            return
        }
        let previousTask = connectionTimeoutTask
        connectionTimeoutTask = task
        stateLock.unlock()
        previousTask?.cancel()
    }

    private func pauseConnectionTimeout() {
        stateLock.lock()
        let timeoutTask = connectionTimeoutTask
        connectionTimeoutTask = nil
        stateLock.unlock()
        timeoutTask?.cancel()
    }

    private func closeTransport() {
        stateLock.lock()
        let sessionChannel = self.sessionChannel
        let channel = self.channel
        stateLock.unlock()

        sessionChannel?.close(promise: nil)
        if let channel {
            // Keep the connection alive until the channel has actually closed.
            // The session model releases its reference immediately when leaving
            // the terminal, so a weak capture here would strand the event loop.
            channel.closeFuture.whenComplete { _ in
                self.shutdownGroup()
            }
            channel.close(promise: nil)
        } else {
            shutdownGroup()
        }
    }

    private func installTransportChannel(_ channel: Channel) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard terminationReason == nil else {
            return false
        }
        self.channel = channel
        return true
    }

    private func installSessionChannel(_ channel: Channel) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard terminationReason == nil else {
            return false
        }
        sessionChannel = channel
        return true
    }

    private func currentSessionChannel() -> Channel? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard terminationReason == nil else {
            return nil
        }
        return sessionChannel
    }

    private func currentTransportChannel() -> Channel? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard terminationReason == nil else {
            return nil
        }
        return channel
    }

    private func notify(_ state: SSHConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange(state)
        }
    }

    private func shutdownGroup() {
        stateLock.lock()
        guard let group else {
            stateLock.unlock()
            return
        }
        self.group = nil
        stateLock.unlock()
        group.shutdownGracefully { _ in }
    }
}
