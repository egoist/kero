import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum TestSSHAuthentication {
    case password(username: String, password: String)
    case publicKey(username: String, key: NIOSSHPublicKey)

    static let releasePassword = TestSSHAuthentication.password(
        username: "release",
        password: "integration-secret"
    )
}

struct TestSSHCommandResponse {
    let stdout: String
    let stderr: String
    let exitStatus: Int

    init(
        stdout: String,
        stderr: String = "",
        exitStatus: Int = 0
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }
}

final class TestSSHServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let authentication: TestSSHAuthentication
    private var channel: Channel?

    var onInput: ((Data) -> Void)?
    var onResize: ((SSHChannelRequestEvent.WindowChangeRequest) -> Void)?
    var onExec: ((String) -> TestSSHCommandResponse)?

    init(authentication: TestSSHAuthentication = .releasePassword) {
        self.authentication = authentication
    }

    var port: Int {
        channel?.localAddress?.port ?? 0
    }

    func start() throws {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let authentication = TestAuthenticationDelegate(
            authentication: authentication
        )

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else {
                        return
                    }
                    let handler = NIOSSHHandler(
                        role: .server(
                            .init(
                                hostKeys: [hostKey],
                                userAuthDelegate: authentication
                            )
                        ),
                        allocator: channel.allocator
                    ) { [weak self] childChannel, channelType in
                        guard let self, channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(
                                TestSSHServerError.invalidChannelType
                            )
                        }
                        return childChannel.eventLoop.makeCompletedFuture {
                            try childChannel.pipeline.syncOperations.addHandler(
                                TestShellHandler(
                                    onInput: { [weak self] data in
                                        self?.onInput?(data)
                                    },
                                    onResize: { [weak self] request in
                                        self?.onResize?(request)
                                    },
                                    onExec: { [weak self] command in
                                        self?.onExec?(command)
                                            ?? TestSSHCommandResponse(
                                                stdout: "",
                                                stderr: "Unsupported command",
                                                exitStatus: 127
                                            )
                                    }
                                )
                            )
                            try childChannel.pipeline.syncOperations.addHandler(
                                TestServerErrorHandler()
                            )
                        }
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(
                        TestServerErrorHandler()
                    )
                }
            }
            .serverChannelOption(
                ChannelOptions.socket(
                    SocketOptionLevel(SOL_SOCKET),
                    SO_REUSEADDR
                ),
                value: 1
            )
            .childChannelOption(
                ChannelOptions.socket(
                    SocketOptionLevel(IPPROTO_TCP),
                    TCP_NODELAY
                ),
                value: 1
            )

        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    }

    func stop() throws {
        if let channel {
            try channel.close().wait()
            self.channel = nil
        }
        try group.syncShutdownGracefully()
    }
}

final class TestSilentTCPServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: Channel?
    private var childChannel: Channel?

    var port: Int {
        channel?.localAddress?.port ?? 0
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { [weak self] channel in
                self?.lock.lock()
                self?.childChannel = channel
                self?.lock.unlock()
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .serverChannelOption(
                ChannelOptions.socket(
                    SocketOptionLevel(SOL_SOCKET),
                    SO_REUSEADDR
                ),
                value: 1
            )

        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    }

    func stop() throws {
        lock.lock()
        let childChannel = childChannel
        self.childChannel = nil
        lock.unlock()
        try childChannel?.close().wait()
        if let channel {
            try channel.close().wait()
            self.channel = nil
        }
        try group.syncShutdownGracefully()
    }
}

private enum TestSSHServerError: Error {
    case invalidChannelType
}

private final class TestAuthenticationDelegate:
    NIOSSHServerUserAuthenticationDelegate
{
    private let authentication: TestSSHAuthentication

    var supportedAuthenticationMethods:
        NIOSSHAvailableUserAuthenticationMethods
    {
        switch authentication {
        case .password:
            .password
        case .publicKey:
            .publicKey
        }
    }

    init(authentication: TestSSHAuthentication) {
        self.authentication = authentication
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        let accepted: Bool
        switch (authentication, request.request) {
        case let (
            .password(expectedUsername, expectedPassword),
            .password(offer)
        ):
            accepted = request.username == expectedUsername
                && offer.password == expectedPassword
        case let (
            .publicKey(expectedUsername, expectedKey),
            .publicKey(offer)
        ):
            accepted = request.username == expectedUsername
                && offer.publicKey == expectedKey
        default:
            accepted = false
        }
        responsePromise.succeed(accepted ? .success : .failure)
    }
}

private final class TestShellHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let onInput: (Data) -> Void
    private let onResize: (SSHChannelRequestEvent.WindowChangeRequest) -> Void
    private let onExec: (String) -> TestSSHCommandResponse

    init(
        onInput: @escaping (Data) -> Void,
        onResize: @escaping (SSHChannelRequestEvent.WindowChangeRequest) -> Void,
        onExec: @escaping (String) -> TestSSHCommandResponse
    ) {
        self.onInput = onInput
        self.onResize = onResize
        self.onExec = onExec
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard payload.type == .channel,
              case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        onInput(Data(bytes))

        var echo = context.channel.allocator.buffer(capacity: bytes.count)
        echo.writeBytes(bytes)
        context.writeAndFlush(
            wrapOutboundOut(
                SSHChannelData(
                    type: .channel,
                    data: .byteBuffer(echo)
                )
            ),
            promise: nil
        )
    }

    func userInboundEventTriggered(
        context: ChannelHandlerContext,
        event: Any
    ) {
        switch event {
        case let request as SSHChannelRequestEvent.ShellRequest:
            if request.wantReply {
                context.triggerUserOutboundEvent(
                    ChannelSuccessEvent(),
                    promise: nil
                )
            }
            send(
                "Kero integration shell\r\n$ ",
                context: context
            )
        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            onResize(request)
        case let request as SSHChannelRequestEvent.ExecRequest:
            if request.wantReply {
                context.triggerUserOutboundEvent(
                    ChannelSuccessEvent(),
                    promise: nil
                )
            }
            let response = onExec(request.command)
            let stdoutFuture = send(
                response.stdout,
                type: .channel,
                context: context
            )
            let stderrFuture = send(
                response.stderr,
                type: .stdErr,
                context: context
            )
            stdoutFuture.and(stderrFuture).flatMap { _ in
                context.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExitStatus(
                        exitStatus: response.exitStatus
                    )
                )
            }.whenComplete { _ in
                context.close(promise: nil)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    @discardableResult
    private func send(
        _ text: String,
        type: SSHChannelData.DataType = .channel,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        guard !text.isEmpty else {
            return context.eventLoop.makeSucceededVoidFuture()
        }
        var buffer = context.channel.allocator.buffer(
            capacity: text.utf8.count
        )
        buffer.writeString(text)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(
            wrapOutboundOut(
                SSHChannelData(
                    type: type,
                    data: .byteBuffer(buffer)
                )
            ),
            promise: promise
        )
        return promise.futureResult
    }
}

private final class TestServerErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
