import Cocoa
import GhosttyTerminal
import ShellCraftKit

private final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

final class ViewController: NSViewController {
    private lazy var terminalView: TerminalView = .init(
        frame: NSRect(x: 0, y: 0, width: 720, height: 480)
    )

    private lazy var shellSession: ShellSession = .init(shell: defaultSandboxShell)

    private lazy var controller: TerminalController = .init { builder in
        builder.withBackgroundOpacity(0)
        builder.withCustom("keybind", "super+k=text:\\x0c")
    }

    override func loadView() {
        let container = AppearanceAwareView()
        container.onAppearanceChange = { [weak self] in
            self?.applyWindowBackgroundColor()
        }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        configureTerminalView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        activateTerminal()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.fitToSize()
    }

    private func configureView() {
        view.wantsLayer = true
        applyWindowBackgroundColor()
    }

    private func applyWindowBackgroundColor() {
        // `NSColor.windowBackgroundColor.cgColor` snapshots whichever
        // appearance is current at the call site, so drawing it naively
        // caches yesterday's light/dark value on the layer. Resolve it
        // under the view's effective appearance so the layer follows
        // system toggles.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func configureTerminalView() {
        terminalView.delegate = self
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityIdentifier("terminal.surface")
        terminalView.setAccessibilityLabel("Terminal Surface")
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(shellSession.terminalSession)
        )
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func activateTerminal() {
        view.window?.makeFirstResponder(terminalView)
        shellSession.start()
    }
}

// MARK: - Terminal Callbacks

extension ViewController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        view.window?.title = title
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        view.window?.close()
    }
}
