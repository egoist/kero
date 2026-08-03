import GhosttyTerminal
import UIKit

/// Keeps real pastes bracketed while turning UIKit's Return-only "paste"
/// into the carriage return an interactive SSH PTY expects.
struct SSHPTYInputNormalizer {
    private static let bracketedPasteStart = Data("\u{1B}[200~".utf8)
    private static let bracketedPasteEnd = Data("\u{1B}[201~".utf8)
    private static let maximumBufferedPasteBytes = 1_024 * 1_024

    private var pendingPaste: Data?

    mutating func process(_ data: Data) -> Data? {
        if var pendingPaste {
            if data == Self.bracketedPasteEnd {
                self.pendingPaste = nil
                if pendingPaste == Data([0x0A])
                    || pendingPaste == Data([0x0D])
                    || pendingPaste == Data([0x0D, 0x0A])
                {
                    return Data([0x0D])
                }

                var paste = Self.bracketedPasteStart
                paste.append(pendingPaste)
                paste.append(Self.bracketedPasteEnd)
                return paste
            }

            pendingPaste.append(data)
            if pendingPaste.count > Self.maximumBufferedPasteBytes {
                self.pendingPaste = nil
                var unbufferedPaste = Self.bracketedPasteStart
                unbufferedPaste.append(pendingPaste)
                return unbufferedPaste
            }
            self.pendingPaste = pendingPaste
            return nil
        }

        if data == Self.bracketedPasteStart {
            pendingPaste = Data()
            return nil
        }

        return data.contains(0x0A)
            ? Data(data.map { $0 == 0x0A ? 0x0D : $0 })
            : data
    }

    mutating func reset() {
        pendingPaste = nil
    }
}

private final class TerminalTransportBridge: @unchecked Sendable {
    private let lock = NSLock()
    private weak var connection: SSHConnection?
    private var inputNormalizer = SSHPTYInputNormalizer()
    private var lastSize = SSHWindowSize(
        columns: 80,
        rows: 24,
        pixelWidth: 0,
        pixelHeight: 0
    )

    func attach(_ connection: SSHConnection) {
        lock.lock()
        self.connection = connection
        inputNormalizer.reset()
        lock.unlock()
    }

    func detach(_ expectedConnection: SSHConnection) {
        lock.lock()
        if connection === expectedConnection {
            connection = nil
            inputNormalizer.reset()
        }
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        let terminalData = inputNormalizer.process(data)
        let connection = connection
        lock.unlock()
        if let terminalData {
            connection?.send(terminalData)
        }
    }

    func resize(_ viewport: InMemoryTerminalViewport) {
        let size = SSHWindowSize(
            columns: max(Int(viewport.columns), 1),
            rows: max(Int(viewport.rows), 1),
            pixelWidth: Int(viewport.widthPixels),
            pixelHeight: Int(viewport.heightPixels)
        )
        lock.lock()
        lastSize = size
        let connection = connection
        lock.unlock()
        connection?.resize(size)
    }

    var windowSize: SSHWindowSize {
        lock.lock()
        let size = lastSize
        lock.unlock()
        return size
    }
}

@MainActor
final class KeroTerminalView: UITerminalView,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceOpenURLDelegate
{
    weak var session: TerminalSessionModel?

    private static let defaultFontSize: Float = 14
    private static let maximumCachedOutputBytes = 64 * 1_024

    private let transportBridge: TerminalTransportBridge
    private let terminalSession: InMemoryTerminalSession
    private let ghosttyController: TerminalController
    private var cachedOutput = Data()
    private(set) var configuredFontSize = CGFloat(defaultFontSize)

    override init(frame: CGRect) {
        let transportBridge = TerminalTransportBridge()
        self.transportBridge = transportBridge
        self.terminalSession = InMemoryTerminalSession(
            write: { [weak transportBridge] data in
                transportBridge?.send(data)
            },
            resize: { [weak transportBridge] viewport in
                transportBridge?.resize(viewport)
            }
        )
        self.ghosttyController = TerminalController(
            configuration: Self.terminalConfiguration,
            theme: Self.terminalTheme
        )
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        backgroundColor = .black
        isOpaque = true
        delegate = self
        controller = ghosttyController
        configuration = TerminalSurfaceOptions(
            backend: .inMemory(terminalSession),
            fontSize: Self.defaultFontSize
        )
        // Kero owns the persistent touch-key row below the terminal.
        inputAccessoryItems = []
        accessibilityLabel = "SSH terminal"
        accessibilityIdentifier = "ssh-terminal"
    }

    func attachConnection(_ connection: SSHConnection) {
        transportBridge.attach(connection)
    }

    func detachConnection(_ connection: SSHConnection) {
        transportBridge.detach(connection)
    }

    var windowSize: SSHWindowSize {
        let current = transportBridge.windowSize
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        return SSHWindowSize(
            columns: max(current.columns, 1),
            rows: max(current.rows, 1),
            pixelWidth: current.pixelWidth > 0
                ? current.pixelWidth
                : Int((bounds.width * scale).rounded(.down)),
            pixelHeight: current.pixelHeight > 0
                ? current.pixelHeight
                : Int((bounds.height * scale).rounded(.down))
        )
    }

    var renderedTerminalConfiguration: String {
        ghosttyController.renderedConfig
    }

    func setFontSize(_ size: CGFloat) {
        let resolved = min(max(size, 4), 64)
        guard abs(configuredFontSize - resolved) > 0.01 else {
            return
        }
        configuredFontSize = resolved
        setTerminalFontSize(Float(resolved))
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        cachedOutput.append(data)
        if cachedOutput.count > Self.maximumCachedOutputBytes {
            cachedOutput.removeFirst(
                cachedOutput.count - Self.maximumCachedOutputBytes
            )
        }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing")
            || arguments.contains("-live-ssh-testing") {
            accessibilityValue = String(decoding: cachedOutput, as: UTF8.self)
        }
        #endif
        terminalSession.receive(data)
    }

    func receive(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        receive(Data(normalized.utf8))
    }

    func sendInput(_ data: Data) {
        terminalSession.sendInput(data)
    }

    func viewportText() -> String {
        if let viewport = terminalSession.readViewportText(),
           !viewport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewport
        }
        return String(decoding: cachedOutput, as: UTF8.self)
    }

    func terminalDidChangeTitle(_ title: String) {
        session?.updateTitle(title)
    }

    func terminalDidRingBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        session?.updateWorkingDirectory(path)
    }

    func terminalDidRequestOpenURL(
        _ urlString: String,
        kind _: TerminalOpenURLKind
    ) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            return
        }
        UIApplication.shared.open(url)
    }

    private static let terminalConfiguration = TerminalConfiguration(
        startingFrom: .default
    ) { builder in
        builder.withFontFamily("JetBrains Mono")
        builder.withFontSize(defaultFontSize)
        builder.withFontThicken(false)
        builder.withCursorStyle(.block)
        builder.withCursorStyleBlink(true)
        builder.withWindowPaddingX(0)
        builder.withWindowPaddingY(0)
        builder.withCustom("term", "xterm-256color")
        builder.withCustom("shell-integration", "none")
        builder.withCustom("scrollback-limit", "4194304")
        builder.withCustom("clipboard-read", "deny")
        builder.withCustom("clipboard-write", "allow")
        builder.withCustom("clipboard-paste-protection", "true")
    }

    private static let terminalTheme: TerminalTheme = {
        let colors = TerminalConfiguration(startingFrom: .afterglow) {
            builder in
            builder.withBackground("000000")
            builder.withForeground("DBE3DE")
            builder.withCursorColor("73D19E")
            builder.withSelectionBackground("245A40")
            builder.withSelectionForeground("FFFFFF")
        }
        return TerminalTheme(light: colors, dark: colors)
    }()
}
