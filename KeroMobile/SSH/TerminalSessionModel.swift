import Foundation
import UIKit

@MainActor
final class TerminalSessionModel: ObservableObject, Identifiable {
    @Published private(set) var state: SSHConnectionState = .idle
    @Published private(set) var title: String
    @Published private(set) var isUnlockingCredential = false
    @Published private(set) var thumbnail: UIImage?
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var alert: TerminalSessionAlert?

    let id = UUID()
    let host: SSHHost
    let terminalView: KeroTerminalView
    lazy var remoteProject = RemoteProjectModel { [weak self] command in
        guard let self else {
            throw SSHCommandError.notConnected
        }
        return try await self.executeRemoteCommand(command)
    }

    private let hostStore: HostStore
    private let identityStore: IdentityStore
    private let knownHostStore: KnownHostStore
    private var connection: SSHConnection?
    private var credentialTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var reconnectsAfterBackground = false
    private(set) var isVisible = false

    init(
        host: SSHHost,
        hostStore: HostStore,
        identityStore: IdentityStore,
        knownHostStore: KnownHostStore
    ) {
        self.host = host
        self.title = host.displayName
        self.hostStore = hostStore
        self.identityStore = identityStore
        self.knownHostStore = knownHostStore
        self.terminalView = KeroTerminalView(frame: .zero)
        self.terminalView.session = self
    }

    var statusText: String {
        switch state {
        case .idle:
            "Ready"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        case .failed:
            "Connection failed"
        }
    }

    var isConnected: Bool {
        state == .connected
    }

    func becameVisible() {
        isVisible = true
        resumeIfNeeded()
    }

    func becameHidden() {
        captureThumbnail()
        isVisible = false
    }

    func resumeIfNeeded() {
        switch state {
        case .idle, .disconnected, .failed:
            connect()
        case .connecting, .connected:
            break
        }
    }

    func connect() {
        guard state != .connecting && state != .connected else {
            return
        }

        // Transition before Keychain or LocalAuthentication work so a retry
        // always gives immediate visual feedback, including while Face ID is
        // preparing a protected credential.
        state = .connecting
        alert = nil

        let newConnectionID = UUID()
        connectionID = newConnectionID
        credentialTask?.cancel()
        credentialTask = Task { [weak self] in
            guard let self else {
                return
            }
            isUnlockingCredential = true
            defer {
                if connectionID == newConnectionID {
                    isUnlockingCredential = false
                    credentialTask = nil
                }
            }

            do {
                let credential = try await loadCredential()
                try Task.checkCancellation()
                guard connectionID == newConnectionID else {
                    return
                }
                startConnection(
                    credential: credential,
                    connectionID: newConnectionID
                )
            } catch is CancellationError {
                return
            } catch {
                guard connectionID == newConnectionID else {
                    return
                }
                state = .failed(error.localizedDescription)
                alert = TerminalSessionAlert(
                    title: "Couldn’t connect",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func loadCredential() async throws -> SSHCredential {
        switch host.authentication {
        case .password:
            return .password(
                try await hostStore.passwordForConnection(for: host)
            )
        case .identity:
            guard let identityID = host.identityID else {
                throw IdentityStoreError.identityNotFound
            }
            return .privateKey(
                try await identityStore.privateKeyForConnection(
                    for: identityID,
                    hostName: host.displayName
                )
            )
        }
    }

    private func startConnection(
        credential: SSHCredential,
        connectionID: UUID
    ) {
        let size = terminalView.windowSize
        let configuration = SSHConnectionConfiguration(
            host: host,
            credential: credential,
            term: "xterm-256color",
            environment: ["LANG": Locale.current.identifier + ".UTF-8"],
            initialSize: size
        )

        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { [weak self] openSSHKey, completion in
                DispatchQueue.main.async {
                    guard let self else {
                        completion(false)
                        return
                    }
                    self.evaluateHostKey(
                        openSSHKey,
                        completion: completion
                    )
                }
            },
            onStateChange: { [weak self] newState in
                self?.handle(newState, connectionID: connectionID)
            }
        )
        self.connection = connection
        terminalView.attachConnection(connection)
        connection.connect()
    }

    func reconnect() {
        disconnect()
        terminalView.receive("\r\n[Kero] Reconnecting…\r\n")
        connect()
    }

    func disconnect() {
        rejectHostKey()
        connectionID = UUID()
        credentialTask?.cancel()
        credentialTask = nil
        isUnlockingCredential = false
        if let connection {
            terminalView.detachConnection(connection)
            connection.disconnect()
        }
        connection = nil
        if state != .idle {
            state = .disconnected
        }
        reconnectsAfterBackground = false
    }

    func suspendForBackground() {
        reconnectsAfterBackground = state == .connected || state == .connecting
        rejectHostKey()
        connectionID = UUID()
        credentialTask?.cancel()
        credentialTask = nil
        isUnlockingCredential = false
        if let connection {
            terminalView.detachConnection(connection)
            connection.disconnect()
        }
        connection = nil
        if state != .idle {
            state = .disconnected
        }
    }

    func resumeAfterBackgroundIfVisible() {
        guard reconnectsAfterBackground, isVisible else {
            return
        }
        reconnectsAfterBackground = false
        resumeIfNeeded()
    }

    func send(_ data: Data) {
        terminalView.sendInput(data)
    }

    func send(bytes: [UInt8]) {
        send(Data(bytes))
        _ = terminalView.becomeFirstResponder()
    }

    func focusTerminal() {
        _ = terminalView.becomeFirstResponder()
    }

    func updateWorkingDirectory(_ directory: String?) {
        remoteProject.setWorkingDirectory(directory)
    }

    func captureThumbnail() {
        let lines = terminalView.viewportText()
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstContentIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }),
        let lastContentIndex = lines.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return
        }

        let imageSize = CGSize(width: 320, height: 180)
        let font = MobileTerminalFont.regular(ofSize: 9)
        let maximumLineCount = max(
            Int((imageSize.height - 16) / font.lineHeight),
            1
        )
        let contentLines = Array(lines[firstContentIndex...lastContentIndex])
            .suffix(maximumLineCount)
        let content = contentLines.joined(separator: "\n")

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        thumbnail = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byClipping
            (content as NSString).draw(
                with: CGRect(
                    x: 8,
                    y: 8,
                    width: imageSize.width - 16,
                    height: imageSize.height - 16
                ),
                options: [.usesLineFragmentOrigin],
                attributes: [
                    .font: font,
                    .foregroundColor: UIColor(
                        red: 0.86,
                        green: 0.89,
                        blue: 0.87,
                        alpha: 1
                    ),
                    .paragraphStyle: paragraphStyle,
                ],
                context: nil
            )
        }
    }

    func updateTitle(_ value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        title = cleaned.isEmpty ? host.displayName : String(cleaned.prefix(80))
    }

    func acceptHostKey() {
        guard let prompt = hostKeyPrompt else {
            return
        }
        do {
            try knownHostStore.trust(prompt.proposed)
            hostKeyPrompt = nil
            prompt.resolve(accepted: true)
        } catch {
            hostKeyPrompt = nil
            prompt.resolve(accepted: false)
            alert = TerminalSessionAlert(
                title: "Couldn’t save server identity",
                message: error.localizedDescription
            )
        }
    }

    func rejectHostKey() {
        guard let prompt = hostKeyPrompt else {
            return
        }
        hostKeyPrompt = nil
        prompt.resolve(accepted: false)
    }

    private func evaluateHostKey(
        _ openSSHKey: String,
        completion: @escaping (Bool) -> Void
    ) {
        switch knownHostStore.evaluate(host: host, openSSHKey: openSSHKey) {
        case .trusted:
            completion(true)
        case .unknown(let proposed):
            hostKeyPrompt = HostKeyPrompt(
                kind: .firstConnection,
                proposed: proposed,
                existing: nil,
                resolution: completion
            )
        case .changed(let existing, let proposed):
            hostKeyPrompt = HostKeyPrompt(
                kind: .changed,
                proposed: proposed,
                existing: existing,
                resolution: completion
            )
        }
    }

    private func handle(
        _ newState: SSHConnectionState,
        connectionID: UUID
    ) {
        guard self.connectionID == connectionID else {
            return
        }
        state = newState
        switch newState {
        case .connected:
            hostStore.markConnected(host.id)
            Task { [weak self] in
                await self?.remoteProject.discoverInitialDirectory()
            }
        case .failed(let message):
            if let connection {
                terminalView.detachConnection(connection)
                self.connection = nil
            }
            alert = TerminalSessionAlert(
                title: "SSH connection failed",
                message: message
            )
        case .disconnected:
            if let connection {
                terminalView.detachConnection(connection)
                self.connection = nil
            }
        default:
            break
        }
    }

    private func executeRemoteCommand(
        _ command: String
    ) async throws -> SSHCommandResult {
        guard state == .connected, let connection else {
            throw SSHCommandError.notConnected
        }
        return try await withCheckedThrowingContinuation { continuation in
            connection.execute(command: command) {
                continuation.resume(with: $0)
            }
        }
    }
}

final class HostKeyPrompt: Identifiable {
    enum Kind {
        case firstConnection
        case changed
    }

    let id = UUID()
    let kind: Kind
    let proposed: KnownHostRecord
    let existing: KnownHostRecord?

    private var resolution: ((Bool) -> Void)?

    init(
        kind: Kind,
        proposed: KnownHostRecord,
        existing: KnownHostRecord?,
        resolution: @escaping (Bool) -> Void
    ) {
        self.kind = kind
        self.proposed = proposed
        self.existing = existing
        self.resolution = resolution
    }

    func resolve(accepted: Bool) {
        let resolution = self.resolution
        self.resolution = nil
        resolution?(accepted)
    }
}

struct TerminalSessionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
