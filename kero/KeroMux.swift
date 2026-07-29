//
//  KeroMux.swift
//  kero
//

import Darwin
import Foundation

/// A live PTY owned by Kero's local multiplexer. Layout deliberately stays in
/// the app: the daemon knows sessions, not projects, tabs, panes, or windows.
struct KeroMuxSessionInfo: Codable, Sendable {
    let id: UUID
    let backend: String
    let shellName: String
    let title: String
    let workingDirectory: String
    let shellPID: pid_t
    let foregroundPID: pid_t?
}

private struct KeroMuxMessage: Codable {
    var type: String
    var sessionID: UUID?
    var program: String?
    var arguments: [String]?
    var workingDirectory: String?
    var environment: [String: String]?
    var backend: String?
    var shellName: String?
    var title: String?
    var data: Data?
    var columns: UInt16?
    var rows: UInt16?
    var pixelWidth: UInt16?
    var pixelHeight: UInt16?
    var session: KeroMuxSessionInfo?
    var sessions: [KeroMuxSessionInfo]?
    var message: String?

    init(type: String) {
        self.type = type
    }
}

enum KeroMuxError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): message
        }
    }
}

private enum KeroMuxPaths {
    static let directory: URL = {
        #if DEBUG
        let name = "kero-dev"
        #else
        let name = "kero"
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("mux", isDirectory: true)
    }()

    static var socket: URL {
        directory.appendingPathComponent("mux.sock")
    }

    static var lock: URL {
        directory.appendingPathComponent("mux.lock")
    }

    static var executable: URL {
        if let executable = Bundle.main.executableURL {
            return executable
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
    }
}

private enum KeroMuxWire {
    static let maximumFrameSize = 32 * 1024 * 1024

    static func send(_ message: KeroMuxMessage, to fd: Int32) throws {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maximumFrameSize else {
            throw KeroMuxError.message("multiplexer message is too large")
        }
        var length = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &length) { bytes in
            try writeAll(fd, bytes)
        }
        try payload.withUnsafeBytes { bytes in
            try writeAll(fd, bytes)
        }
    }

    static func receive(from fd: Int32) throws -> KeroMuxMessage? {
        guard let header = try readExact(fd, count: MemoryLayout<UInt32>.size) else {
            return nil
        }
        let encodedLength = header.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        let length = Int(UInt32(bigEndian: encodedLength))
        guard length >= 0, length <= maximumFrameSize else {
            throw KeroMuxError.message("invalid multiplexer message length")
        }
        guard let payload = try readExact(fd, count: length) else {
            throw KeroMuxError.message("multiplexer connection closed mid-message")
        }
        return try JSONDecoder().decode(KeroMuxMessage.self, from: payload)
    }

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(
                fd,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw KeroMuxError.message(
                    "multiplexer write failed: \(String(cString: strerror(errno)))"
                )
            }
        }
    }

    static func readExact(_ fd: Int32, count: Int) throws -> Data? {
        if count == 0 { return Data() }
        var data = Data(count: count)
        var offset = 0
        let completed = try data.withUnsafeMutableBytes { bytes -> Bool in
            while offset < count {
                let result = Darwin.read(
                    fd,
                    bytes.baseAddress?.advanced(by: offset),
                    count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else {
                    throw KeroMuxError.message(
                        "multiplexer read failed: \(String(cString: strerror(errno)))"
                    )
                }
            }
            return true
        }
        return completed ? data : nil
    }
}

private final class KeroMuxConnection {
    let fd: Int32
    private let sendLock = NSLock()
    private let closeLock = NSLock()
    private var isClosed = false

    init(fd: Int32) {
        self.fd = fd
        var enabled: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        )
    }

    deinit {
        close()
    }

    func send(_ message: KeroMuxMessage) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        try KeroMuxWire.send(message, to: fd)
    }

    func receive() throws -> KeroMuxMessage? {
        try KeroMuxWire.receive(from: fd)
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }
}

enum KeroMuxControl {
    static func create(
        launch: TerminalLaunch,
        backend: TerminalBackend,
        shellName: String
    ) throws -> KeroMuxSessionInfo {
        var message = KeroMuxMessage(type: "create")
        message.program = launch.program
        message.arguments = launch.arguments
        message.workingDirectory = launch.workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment.merge(launch.environment) { _, terminalValue in terminalValue }
        environment["KERO_MUX_SESSION"] = "1"
        message.environment = environment
        message.backend = backend.rawValue
        message.shellName = shellName
        let response = try request(message, startServer: true)
        guard response.type == "created", let session = response.session else {
            throw responseError(response)
        }
        return session
    }

    static func info(_ id: UUID) -> KeroMuxSessionInfo? {
        var message = KeroMuxMessage(type: "info")
        message.sessionID = id
        guard let response = try? request(message, startServer: false),
              response.type == "info"
        else { return nil }
        return response.session
    }

    static func list() -> [KeroMuxSessionInfo] {
        let message = KeroMuxMessage(type: "list")
        guard let response = try? request(message, startServer: false),
              response.type == "sessions"
        else { return [] }
        return response.sessions ?? []
    }

    static func checkpoint(_ data: Data, sessionID: UUID) {
        var message = KeroMuxMessage(type: "checkpoint")
        message.sessionID = sessionID
        message.data = data
        _ = try? request(message, startServer: false)
    }

    static func updateMetadata(
        sessionID: UUID,
        title: String? = nil,
        workingDirectory: String? = nil
    ) {
        var message = KeroMuxMessage(type: "metadata")
        message.sessionID = sessionID
        message.title = title
        message.workingDirectory = workingDirectory
        _ = try? request(message, startServer: false)
    }

    static func terminate(_ id: UUID) {
        var message = KeroMuxMessage(type: "terminate")
        message.sessionID = id
        _ = try? request(message, startServer: false)
    }

    static func attachmentLaunch(
        sessionID: UUID,
        workingDirectory: String,
        environment: [String: String]
    ) -> TerminalLaunch {
        let executable = KeroMuxPaths.executable.path
        let arguments = ["+mux-client", sessionID.uuidString]
        let commandLine = ([executable] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
        return TerminalLaunch(
            program: executable,
            arguments: arguments,
            commandLine: commandLine,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    private static func request(
        _ message: KeroMuxMessage,
        startServer: Bool
    ) throws -> KeroMuxMessage {
        let fd = try connect(startServer: startServer)
        let connection = KeroMuxConnection(fd: fd)
        try connection.send(message)
        guard let response = try connection.receive() else {
            throw KeroMuxError.message("multiplexer closed the connection")
        }
        return response
    }

    fileprivate static func connect(startServer: Bool) throws -> Int32 {
        try KeroMuxPaths.prepareDirectory()
        if let fd = tryConnect() { return fd }
        guard startServer else {
            throw KeroMuxError.message("multiplexer is not running")
        }

        let lockFD = Darwin.open(KeroMuxPaths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else {
            throw KeroMuxError.message("could not open the multiplexer lock")
        }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw KeroMuxError.message("could not lock multiplexer startup")
        }

        if let fd = tryConnect() {
            _ = flock(lockFD, LOCK_UN)
            return fd
        }
        _ = Darwin.unlink(KeroMuxPaths.socket.path)
        do {
            try startDaemon()
        } catch {
            _ = flock(lockFD, LOCK_UN)
            throw error
        }
        // The daemon holds this lock for its lifetime. Release the startup
        // claim before polling so the freshly spawned process can acquire it.
        _ = flock(lockFD, LOCK_UN)

        for _ in 0..<100 {
            if let fd = tryConnect() { return fd }
            usleep(20_000)
        }
        throw KeroMuxError.message("multiplexer did not start")
    }

    private static func tryConnect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var enabled: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        )
        do {
            var address = try unixAddress(path: KeroMuxPaths.socket.path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, unixAddressLength(path: KeroMuxPaths.socket.path))
                }
            }
            guard result == 0 else {
                Darwin.close(fd)
                return nil
            }
            return fd
        } catch {
            Darwin.close(fd)
            return nil
        }
    }

    private static func startDaemon() throws {
        let process = Process()
        process.executableURL = KeroMuxPaths.executable
        process.arguments = ["+mux-server"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    fileprivate static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw KeroMuxError.message("multiplexer socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: bytes)
        }
        return address
    }

    fileprivate static func unixAddressLength(path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }

    private static func responseError(_ response: KeroMuxMessage) -> KeroMuxError {
        KeroMuxError.message(response.message ?? "multiplexer request failed")
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Hidden CLI attach process. Its PTY belongs to the selected renderer, while
/// the shell's PTY belongs to the daemon. Keeping the bridge byte-for-byte
/// makes it equally useful to Ghostty and Alacritty and preserves every escape
/// sequence those renderers already understand.
enum KeroMuxClientProcess {
    static func run(sessionID: UUID) throws {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        let fd = try KeroMuxControl.connect(startServer: false)
        let connection = KeroMuxConnection(fd: fd)
        var attach = KeroMuxMessage(type: "attach")
        attach.sessionID = sessionID
        try connection.send(attach)
        guard let response = try connection.receive() else {
            throw KeroMuxError.message("multiplexer closed before attaching")
        }
        guard response.type == "attached" else {
            throw KeroMuxError.message(
                response.message ?? "could not attach to the terminal session"
            )
        }

        // Ghostty launches configured commands through a short-lived login
        // shell, which may print its own "Last login" line before this bridge
        // starts. Clear that renderer-owned PTY before replaying the daemon
        // session so reconnect shows only the durable terminal's output.
        let clearRenderer = Data("\u{1B}[3J\u{1B}[2J\u{1B}[H".utf8)
        try clearRenderer.withUnsafeBytes { bytes in
            try KeroMuxWire.writeAll(STDOUT_FILENO, bytes)
        }

        var original = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        if hasTerminal {
            var raw = original
            cfmakeraw(&raw)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer {
            if hasTerminal {
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
            }
        }

        var lastSize = winsize()
        sendSizeIfChanged(
            connection: connection,
            previous: &lastSize,
            force: true
        )

        var descriptors = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
        ]
        var input = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            descriptors[0].revents = 0
            descriptors[1].revents = 0
            let result = Darwin.poll(&descriptors, nfds_t(descriptors.count), 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw KeroMuxError.message("multiplexer attach poll failed")
            }

            sendSizeIfChanged(
                connection: connection,
                previous: &lastSize,
                force: false
            )

            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let count = Darwin.read(STDIN_FILENO, &input, input.count)
                if count <= 0 { return }
                var message = KeroMuxMessage(type: "input")
                message.data = Data(input[..<count])
                try connection.send(message)
            }

            if descriptors[1].revents & Int16(POLLIN) != 0 {
                guard let message = try connection.receive() else { return }
                switch message.type {
                case "output":
                    if let data = message.data {
                        try data.withUnsafeBytes { bytes in
                            try KeroMuxWire.writeAll(STDOUT_FILENO, bytes)
                        }
                    }
                case "exited", "replaced":
                    return
                case "error":
                    throw KeroMuxError.message(message.message ?? "multiplexer error")
                default:
                    break
                }
            }

            let failureEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            if descriptors[0].revents & failureEvents != 0
                || descriptors[1].revents & failureEvents != 0 {
                return
            }
        }
    }

    private static func sendSizeIfChanged(
        connection: KeroMuxConnection,
        previous: inout winsize,
        force: Bool
    ) {
        var size = winsize()
        guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 else { return }
        guard force
            || size.ws_col != previous.ws_col
            || size.ws_row != previous.ws_row
            || size.ws_xpixel != previous.ws_xpixel
            || size.ws_ypixel != previous.ws_ypixel
        else { return }
        previous = size
        var message = KeroMuxMessage(type: "resize")
        message.columns = max(1, size.ws_col)
        message.rows = max(1, size.ws_row)
        message.pixelWidth = size.ws_xpixel
        message.pixelHeight = size.ws_ypixel
        try? connection.send(message)
    }
}

private final class KeroMuxServerSession {
    let id = UUID()
    let backend: String
    let shellName: String
    let shellPID: pid_t

    private static let replayLimit = 16 * 1024 * 1024
    private static let replayTrimThreshold = replayLimit + 2 * 1024 * 1024
    private let masterFD: Int32
    private let lock = NSLock()
    private var attached: KeroMuxConnection?
    private var replay = Data()
    private var title: String
    private var workingDirectory: String
    private var hasExited = false
    var onExit: ((UUID) -> Void)?

    init(
        program: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String],
        backend: String,
        shellName: String
    ) throws {
        self.backend = backend
        self.shellName = shellName
        self.title = shellName
        self.workingDirectory = workingDirectory

        let programCopy = strdup(program)
        let argumentStrings = [program] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        let argumentCopies: [UnsafeMutablePointer<CChar>?] = argumentStrings.map {
            strdup($0)
        }
        let environmentCopies: [UnsafeMutablePointer<CChar>?] = environmentStrings.map {
            strdup($0)
        }
        let directoryCopy = strdup(workingDirectory)
        defer {
            free(programCopy)
            free(directoryCopy)
            argumentCopies.forEach { free($0) }
            environmentCopies.forEach { free($0) }
        }
        guard let programCopy, let directoryCopy,
              argumentCopies.allSatisfy({ $0 != nil }),
              environmentCopies.allSatisfy({ $0 != nil })
        else {
            throw KeroMuxError.message("could not allocate terminal launch arguments")
        }

        var argv = argumentCopies + [nil]
        var envp = environmentCopies + [nil]
        var master: Int32 = -1
        var initialSize = winsize(
            ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0
        )
        var spawnedPID: pid_t = -1
        argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envBuffer in
                spawnedPID = forkpty(&master, nil, nil, &initialSize)
                if spawnedPID == 0 {
                    guard Darwin.chdir(directoryCopy) == 0 else { _exit(126) }
                    Darwin.execve(programCopy, argvBuffer.baseAddress, envBuffer.baseAddress)
                    _exit(127)
                }
            }
        }
        guard spawnedPID > 0, master >= 0 else {
            if master >= 0 { Darwin.close(master) }
            throw KeroMuxError.message(
                "could not start terminal process: \(String(cString: strerror(errno)))"
            )
        }
        shellPID = spawnedPID
        masterFD = master
    }

    deinit {
        Darwin.close(masterFD)
    }

    func startReading() {
        Thread.detachNewThread { [weak self] in
            self?.readOutput()
        }
    }

    func info() -> KeroMuxSessionInfo {
        lock.lock()
        defer { lock.unlock() }
        let foreground = tcgetpgrp(masterFD)
        return KeroMuxSessionInfo(
            id: id,
            backend: backend,
            shellName: shellName,
            title: title,
            workingDirectory: workingDirectory,
            shellPID: shellPID,
            foregroundPID: foreground > 0 ? foreground : nil
        )
    }

    func attach(_ connection: KeroMuxConnection) throws {
        lock.lock()
        defer { lock.unlock() }
        if let previous = attached, previous !== connection {
            var replaced = KeroMuxMessage(type: "replaced")
            replaced.message = "This terminal session was attached in another window."
            try? previous.send(replaced)
            previous.close()
        }
        var message = KeroMuxMessage(type: "attached")
        message.session = infoWithoutLock()
        try connection.send(message)
        if !replay.isEmpty {
            var output = KeroMuxMessage(type: "output")
            output.data = replay
            try connection.send(output)
        }
        attached = connection
    }

    func detach(_ connection: KeroMuxConnection) {
        lock.lock()
        if attached === connection {
            attached = nil
        }
        lock.unlock()
    }

    func writeInput(_ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    masterFD,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    func resize(
        columns: UInt16,
        rows: UInt16,
        pixelWidth: UInt16,
        pixelHeight: UInt16
    ) {
        var size = winsize(
            ws_row: max(1, rows),
            ws_col: max(1, columns),
            ws_xpixel: pixelWidth,
            ws_ypixel: pixelHeight
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    func checkpoint(_ data: Data) {
        lock.lock()
        replay = data.suffix(Self.replayLimit)
        lock.unlock()
    }

    func updateMetadata(title: String?, workingDirectory: String?) {
        lock.lock()
        if let title, !title.isEmpty { self.title = title }
        if let workingDirectory, !workingDirectory.isEmpty {
            self.workingDirectory = workingDirectory
        }
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let alreadyExited = hasExited
        lock.unlock()
        guard !alreadyExited else { return }
        _ = Darwin.kill(-shellPID, SIGHUP)
        _ = Darwin.kill(shellPID, SIGHUP)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            _ = Darwin.kill(-self.shellPID, SIGKILL)
            _ = Darwin.kill(self.shellPID, SIGKILL)
        }
    }

    private func readOutput() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 {
                receiveOutput(Data(buffer[..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }

        var status: Int32 = 0
        while waitpid(shellPID, &status, 0) < 0, errno == EINTR {}

        lock.lock()
        hasExited = true
        let connection = attached
        attached = nil
        lock.unlock()
        if let connection {
            try? connection.send(KeroMuxMessage(type: "exited"))
            connection.close()
        }
        onExit?(id)
    }

    private func receiveOutput(_ data: Data) {
        lock.lock()
        replay.append(data)
        // Trim in batches instead of moving a full 16 MB buffer for every
        // small PTY read once the cap is reached.
        if replay.count > Self.replayTrimThreshold {
            replay.removeFirst(replay.count - Self.replayLimit)
        }
        let connection = attached
        if let connection {
            var message = KeroMuxMessage(type: "output")
            message.data = data
            do {
                try connection.send(message)
            } catch {
                attached = nil
                connection.close()
            }
        }
        lock.unlock()
    }

    private func infoWithoutLock() -> KeroMuxSessionInfo {
        let foreground = tcgetpgrp(masterFD)
        return KeroMuxSessionInfo(
            id: id,
            backend: backend,
            shellName: shellName,
            title: title,
            workingDirectory: workingDirectory,
            shellPID: shellPID,
            foregroundPID: foreground > 0 ? foreground : nil
        )
    }
}

enum KeroMuxServer {
    static func run() throws {
        // The server owns PTYs beyond the launching app's lifetime. Give it a
        // separate process session and do not inherit a terminal hangup from
        // the app-side CLI harness.
        _ = Darwin.setsid()
        _ = Darwin.signal(SIGHUP, SIG_IGN)
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        try KeroMuxPaths.prepareDirectory()

        let lockFD = Darwin.open(KeroMuxPaths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD) }
            return
        }
        defer {
            _ = flock(lockFD, LOCK_UN)
            _ = Darwin.close(lockFD)
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw KeroMuxError.message("could not create multiplexer socket")
        }
        defer { Darwin.close(listener) }
        _ = Darwin.unlink(KeroMuxPaths.socket.path)
        defer { _ = Darwin.unlink(KeroMuxPaths.socket.path) }

        var address = try KeroMuxControl.unixAddress(path: KeroMuxPaths.socket.path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listener,
                    $0,
                    KeroMuxControl.unixAddressLength(path: KeroMuxPaths.socket.path)
                )
            }
        }
        guard bound == 0 else {
            throw KeroMuxError.message(
                "could not bind multiplexer socket: \(String(cString: strerror(errno)))"
            )
        }
        _ = Darwin.chmod(KeroMuxPaths.socket.path, 0o600)
        guard Darwin.listen(listener, 32) == 0 else {
            throw KeroMuxError.message("could not listen on multiplexer socket")
        }

        let daemon = KeroMuxDaemon()
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                throw KeroMuxError.message("multiplexer accept failed")
            }
            var peerUID = uid_t.max
            var peerGID = gid_t.max
            guard getpeereid(fd, &peerUID, &peerGID) == 0,
                  peerUID == getuid()
            else {
                Darwin.close(fd)
                continue
            }
            let connection = KeroMuxConnection(fd: fd)
            Thread.detachNewThread {
                daemon.handle(connection)
            }
        }
    }
}

private final class KeroMuxDaemon {
    private let lock = NSLock()
    private var sessions: [UUID: KeroMuxServerSession] = [:]

    func handle(_ connection: KeroMuxConnection) {
        defer { connection.close() }
        do {
            guard let request = try connection.receive() else { return }
            switch request.type {
            case "create":
                try create(request, connection: connection)
            case "attach":
                try attach(request, connection: connection)
            case "list":
                var response = KeroMuxMessage(type: "sessions")
                response.sessions = allSessions().map { $0.info() }
                try connection.send(response)
            case "info":
                guard let session = session(for: request.sessionID) else {
                    try sendError("Terminal session is no longer running.", to: connection)
                    return
                }
                var response = KeroMuxMessage(type: "info")
                response.session = session.info()
                try connection.send(response)
            case "checkpoint":
                guard let session = session(for: request.sessionID),
                      let data = request.data
                else {
                    try sendError("Terminal session is no longer running.", to: connection)
                    return
                }
                session.checkpoint(data)
                try connection.send(KeroMuxMessage(type: "ok"))
            case "metadata":
                guard let session = session(for: request.sessionID) else {
                    try sendError("Terminal session is no longer running.", to: connection)
                    return
                }
                session.updateMetadata(
                    title: request.title,
                    workingDirectory: request.workingDirectory
                )
                try connection.send(KeroMuxMessage(type: "ok"))
            case "terminate":
                guard let session = session(for: request.sessionID) else {
                    try sendError("Terminal session is no longer running.", to: connection)
                    return
                }
                session.terminate()
                try connection.send(KeroMuxMessage(type: "ok"))
            default:
                try sendError("Unknown multiplexer request.", to: connection)
            }
        } catch {
            try? sendError(String(describing: error), to: connection)
        }
    }

    private func create(
        _ request: KeroMuxMessage,
        connection: KeroMuxConnection
    ) throws {
        guard let program = request.program,
              let arguments = request.arguments,
              let workingDirectory = request.workingDirectory,
              let environment = request.environment,
              let backend = request.backend,
              let shellName = request.shellName
        else {
            try sendError("Incomplete terminal launch request.", to: connection)
            return
        }
        let session = try KeroMuxServerSession(
            program: program,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            backend: backend,
            shellName: shellName
        )
        session.onExit = { [weak self] id in
            self?.remove(id)
        }
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
        session.startReading()

        var response = KeroMuxMessage(type: "created")
        response.session = session.info()
        try connection.send(response)
    }

    private func attach(
        _ request: KeroMuxMessage,
        connection: KeroMuxConnection
    ) throws {
        guard let session = session(for: request.sessionID) else {
            try sendError("Terminal session is no longer running.", to: connection)
            return
        }
        try session.attach(connection)
        defer { session.detach(connection) }
        while let message = try connection.receive() {
            switch message.type {
            case "input":
                if let data = message.data { session.writeInput(data) }
            case "resize":
                session.resize(
                    columns: message.columns ?? 80,
                    rows: message.rows ?? 24,
                    pixelWidth: message.pixelWidth ?? 0,
                    pixelHeight: message.pixelHeight ?? 0
                )
            case "detach":
                return
            default:
                break
            }
        }
    }

    private func session(for id: UUID?) -> KeroMuxServerSession? {
        guard let id else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    private func allSessions() -> [KeroMuxServerSession] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }

    private func remove(_ id: UUID) {
        lock.lock()
        sessions[id] = nil
        lock.unlock()
    }

    private func sendError(
        _ text: String,
        to connection: KeroMuxConnection
    ) throws {
        var response = KeroMuxMessage(type: "error")
        response.message = text
        try connection.send(response)
    }
}
