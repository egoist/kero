import GhosttyTerminal
import GhosttyTheme
import ShellCraftKit
import UIKit

final class ViewController: UIViewController {
    private static let lightThemeKey = "SelectedTheme.light"
    private static let darkThemeKey = "SelectedTheme.dark"

    private lazy var terminalView: TerminalView = .init(frame: .zero)
    private lazy var shellSession: ShellSession = .init(shell: defaultSandboxShell)
    private lazy var controller: TerminalController = .init(
        theme: Self.savedTerminalTheme()
    ) { builder in
        builder.withBackgroundOpacity(0)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Terminal"
        view.backgroundColor = .systemBackground
        view.isOpaque = true
        configureTerminalView()
        configureThemeMenu()
        applyBackgroundForCurrentAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateTerminal()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView.fitToSize()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else {
            return
        }
        controller.setTheme(Self.savedTerminalTheme())
        applyBackgroundForCurrentAppearance()
    }

    private func configureTerminalView() {
        terminalView.delegate = self
        terminalView.isAccessibilityElement = true
        terminalView.accessibilityIdentifier = "terminal.surface"
        terminalView.accessibilityLabel = "Terminal Surface"
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(shellSession.terminalSession)
        )
        terminalView.controller = controller
        terminalView.backgroundColor = .clear
        terminalView.isOpaque = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func activateTerminal() {
        terminalView.becomeFirstResponder()
        shellSession.start()
    }

    // MARK: - Persistence

    private static func savedTerminalTheme() -> TerminalTheme {
        let lightConfig = savedThemeDefinition(forKey: lightThemeKey)?
            .toTerminalConfiguration() ?? .alabaster
        let darkConfig = savedThemeDefinition(forKey: darkThemeKey)?
            .toTerminalConfiguration() ?? .afterglow
        return TerminalTheme(light: lightConfig, dark: darkConfig)
    }

    private static func savedThemeDefinition(
        forKey key: String
    ) -> GhosttyThemeDefinition? {
        guard let name = UserDefaults.standard.string(forKey: key) else {
            return nil
        }
        return GhosttyThemeCatalog.theme(named: name)
    }

    private var isDarkMode: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private func saveTheme(_ theme: GhosttyThemeDefinition) {
        let key = isDarkMode ? Self.darkThemeKey : Self.lightThemeKey
        UserDefaults.standard.set(theme.name, forKey: key)
    }

    private func applyBackgroundForCurrentAppearance() {
        let key = isDarkMode ? Self.darkThemeKey : Self.lightThemeKey
        guard let theme = Self.savedThemeDefinition(forKey: key) else { return }
        if let bgColor = UIColor(hexString: theme.background) {
            view.backgroundColor = bgColor
        }
    }

    // MARK: - Theme Menu

    private func configureThemeMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "paintpalette"),
            menu: buildThemeMenu()
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "terminal.themeButton"
    }

    private func buildThemeMenu() -> UIMenu {
        let popular = buildSubmenu(
            title: "Popular",
            themes: [
                "Dracula", "Catppuccin Mocha", "Catppuccin Latte",
                "Nord", "Solarized Dark", "Solarized Light",
                "Gruvbox Dark", "Gruvbox Light", "Tokyo Night",
                "One Half Dark", "One Half Light", "Rose Pine",
                "Monokai Pro", "GitHub Dark", "GitHub Light",
            ]
        )

        let dark = UIMenu(
            title: "Dark",
            image: UIImage(systemName: "moon.fill"),
            children: alphabeticalSubmenus(
                themes: GhosttyThemeCatalog.allThemes.filter(\.isDark)
            )
        )

        let light = UIMenu(
            title: "Light",
            image: UIImage(systemName: "sun.max.fill"),
            children: alphabeticalSubmenus(
                themes: GhosttyThemeCatalog.allThemes.filter { !$0.isDark }
            )
        )

        return UIMenu(title: "Theme", children: [popular, dark, light])
    }

    private func buildSubmenu(
        title: String,
        themes names: [String]
    ) -> UIMenu {
        let actions = names.compactMap { name -> UIAction? in
            guard let theme = GhosttyThemeCatalog.theme(named: name) else {
                return nil
            }
            return themeAction(for: theme)
        }
        return UIMenu(
            title: title,
            image: UIImage(systemName: "star.fill"),
            children: actions
        )
    }

    private func alphabeticalSubmenus(
        themes: [GhosttyThemeDefinition]
    ) -> [UIMenu] {
        var grouped: [String: [GhosttyThemeDefinition]] = [:]
        for theme in themes {
            let letter = String(theme.name.prefix(1)).uppercased()
            let key = letter.first?.isLetter == true ? letter : "#"
            grouped[key, default: []].append(theme)
        }

        return grouped.keys.sorted().map { key in
            UIMenu(
                title: key,
                children: grouped[key]!.map { themeAction(for: $0) }
            )
        }
    }

    private func themeAction(for theme: GhosttyThemeDefinition) -> UIAction {
        UIAction(title: theme.name) { [weak self] _ in
            self?.applyTheme(theme)
        }
    }

    private func applyTheme(_ theme: GhosttyThemeDefinition) {
        saveTheme(theme)
        controller.setTheme(Self.savedTerminalTheme())

        if let bgColor = UIColor(hexString: theme.background) {
            view.backgroundColor = bgColor
        }
    }
}

// MARK: - Terminal Callbacks

extension ViewController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceTextSelectionRequestDelegate,
    UIAdaptivePresentationControllerDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        ApplicationExitController.requestExit()
    }

    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        let selectionVC = TerminalSelectionViewController(
            text: request.text,
            anchorRange: request.anchorRange
        )
        selectionVC.onDone = { [weak self] in
            self?.terminalView.becomeFirstResponder()
        }
        let nav = UINavigationController(rootViewController: selectionVC)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        nav.presentationController?.delegate = self
        present(nav, animated: true)
    }

    /// Covers the user-gesture (grabber swipe) dismiss path only —
    /// programmatic dismiss does not trigger this callback, so the Done
    /// button restores focus via `onDone` instead.
    func presentationControllerDidDismiss(_: UIPresentationController) {
        terminalView.becomeFirstResponder()
    }
}

// MARK: - UIColor Hex

private extension UIColor {
    convenience init?(hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard hex.count == 6,
              let r = UInt8(hex.prefix(2), radix: 16),
              let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
