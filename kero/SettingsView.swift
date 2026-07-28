//
//  SettingsView.swift
//  kero
//

import AppKit
import GhosttyTheme
import SwiftUI

/// The app settings window (Cmd+,).
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared
    @State private var relaunchError = ""
    @State private var isShowingRelaunchError = false

    /// Nil until the switch is used: a command the picker has no entry for is
    /// one the user wrote, so the field shows itself.
    @State private var isShellEnteredManually: Bool?

    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()

    /// Shells found on this Mac, login shell first.
    private let installedShells = TerminalSession.installedShells()

    /// Label column the Terminal section's two multi-line rows share, so the
    /// backend cards, the shell picker, and both captions start on one line.
    private static let terminalLabelWidth: CGFloat = 58

    var body: some View {
        CappedIdealHeight(maxHeight: 600) { form }
    }

    private var form: some View {
        Form {
            Section("Appearance") {
                // A plain row rather than LabeledContent: that stamps its own
                // label onto every child, leaving all three previews named
                // "Theme" to VoiceOver instead of System/Light/Dark.
                HStack {
                    Text("Theme")
                    Spacer()
                    ThemePicker(selection: $settings.theme)
                }

                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }

                if settings.languageRequiresRelaunch {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Relaunch Kero to apply the language change.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Kero") {
                            relaunch()
                        }
                    }
                }
            }

            Section("Colors") {
                Picker("Dark theme", selection: $settings.themeDark) {
                    ForEach(Self.darkThemeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Picker("Light theme", selection: $settings.themeLight) {
                    ForEach(Self.lightThemeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Text("Colors for the whole window, one theme per appearance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Font") {
                Picker("Family", selection: $settings.fontFamily) {
                    Text("\(TerminalFont.bundledFamily) (Bundled)").tag("")
                    Divider()
                    ForEach(families.dropFirst(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            Section("Sidebar") {
                HStack {
                    Text("Font size")
                    Slider(
                        value: $settings.sidebarFontSize,
                        in: AppSettings.sidebarFontSizeRange,
                        step: 1
                    )
                    .accessibilityLabel("Sidebar font size")
                    Text("\(Int(settings.sidebarFontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.sidebarFontSize,
                        in: AppSettings.sidebarFontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                    .accessibilityLabel("Sidebar font size")
                }
            }

            Section("Preview") {
                // Exercises regular/bold plus Nerd Font icon fallback.
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "kero ❯ echo \"the quick brown fox\" 0O 1lI")
                    Text(verbatim: "\u{E0A0} main \u{E0B0} ~/dev/kero \u{E711} \u{F024B} \u{F0A7D}")
                    Text(verbatim: "bold — permission denied (os error 13)")
                        .bold()
                }
                .font(Font(previewFont))
                .padding(.vertical, 4)
            }

            Section("Terminal") {
                // Only show this once there is a real choice. `selectable`
                // omits backends this build cannot create, so every tab here
                // takes effect instead of silently producing a dead pane.
                if TerminalBackend.selectable.count > 1 {
                    HStack(alignment: .top) {
                        Text("Backend")
                            .frame(width: Self.terminalLabelWidth, alignment: .leading)
                        VStack(alignment: .leading, spacing: 8) {
                            TerminalBackendPicker(selection: $settings.terminalBackend)
                            Text("Changes apply to new terminals.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(alignment: .top) {
                    Text("Shell")
                        .frame(width: Self.terminalLabelWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Shell", selection: shellChoice) {
                            Text("Login shell (\(TerminalSession.loginShell()))")
                                .tag(ShellChoice.loginShell)
                            ForEach(installedShells, id: \.self) { shell in
                                Text(verbatim: shell).tag(ShellChoice.installed(shell))
                            }
                            Divider()
                            Text("Custom command…").tag(ShellChoice.custom)
                        }
                        .labelsHidden()

                        if isCustomShell {
                            TextField(
                                "Shell",
                                text: $settings.terminalCommand,
                                prompt: Text(verbatim: TerminalSession.loginShell())
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        }

                        if isCustomShell, unresolvedShellProgram != nil {
                            Label(
                                "Nothing executable at that path. New terminals keep using your login shell.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        } else if isCustomShell {
                            Text("The whole command line, with any arguments it needs. Use a full path.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Changes apply to new terminals.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                Toggle("Thicken font strokes", isOn: $settings.fontThicken)
                Text("Renders terminal text with slightly heavier strokes, like classic macOS font smoothing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Use Option as Alt/Meta",
                    isOn: $settings.macosOptionAsAlt
                )
                Text("Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Restore session history on relaunch",
                    isOn: $settings.restoreTerminalHistory
                )
                Text("Reopened terminals show their previous scrollback above a fresh shell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Text Editing") {
                Toggle("Wrap lines to editor width", isOn: $settings.wrapLines)
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: $updater.automaticallyChecksForUpdates
                )

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    .disabled(settings.fontFamily.isEmpty
                        && settings.fontSize == AppSettings.defaultFontSize
                        && settings.sidebarFontSize == AppSettings.defaultSidebarFontSize
                        && !settings.fontThicken
                        && !settings.macosOptionAsAlt
                        && settings.language == .system
                        && settings.theme == .system
                        && settings.themeDark == Theme.defaultDarkThemeName
                        && settings.themeLight == Theme.defaultLightThemeName
                        && !settings.wrapLines
                        && !settings.restoreTerminalHistory
                        && settings.terminalBackend == .fallback
                        && settings.terminalCommand.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .alert(
            "Couldn’t Relaunch Kero",
            isPresented: $isShowingRelaunchError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: relaunchError)
        }
    }

    /// What the Shell picker stands for. The stored setting is one string, so
    /// "a command I typed" is the case it cannot express on its own.
    private enum ShellChoice: Hashable {
        case loginShell
        case installed(String)
        case custom
    }

    private var shellChoice: Binding<ShellChoice> {
        Binding(
            get: {
                if isCustomShell { return .custom }
                let command = settings.terminalCommand
                return command.isEmpty ? .loginShell : .installed(command)
            },
            set: { choice in
                switch choice {
                case .loginShell:
                    isShellEnteredManually = false
                    settings.terminalCommand = ""
                case .installed(let shell):
                    isShellEnteredManually = false
                    settings.terminalCommand = shell
                case .custom:
                    // The field opens on whatever is set, so a shell picked a
                    // moment ago is there to add arguments to.
                    isShellEnteredManually = true
                }
            }
        )
    }

    private var isCustomShell: Bool {
        isShellEnteredManually
            ?? (!settings.terminalCommand.isEmpty
                && !installedShells.contains(settings.terminalCommand))
    }

    /// The configured program when it names a path that holds nothing runnable.
    /// A bare name is left alone: `env` resolves it against `PATH` at launch,
    /// which is not this process's `PATH` to check.
    private var unresolvedShellProgram: String? {
        guard let program = TerminalSession.commandTokens(settings.terminalCommand).first,
              program.contains("/"),
              !FileManager.default.isExecutableFile(atPath: program)
        else { return nil }
        return program
    }

    private var previewFont: NSFont {
        TerminalFont.resolve(family: settings.fontFamily, size: CGFloat(settings.fontSize))
    }

    private func relaunch() {
        TerminalManager.saveForRelaunch()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                if let error {
                    relaunchError = error.localizedDescription
                    isShowingRelaunchError = true
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The compact catalog of popular themes shared by both terminal backends,
    /// split by the appearance slot they suit.
    private static let darkThemeNames = Theme.commonDarkThemes.map(\.name)
    private static let lightThemeNames = Theme.commonLightThemes.map(\.name)
}

/// Sizes its sole child to the child's ideal height, capped at `maxHeight`.
/// A `maxHeight` frame plus `fixedSize` can't express this: the grouped Form
/// is a List, which only scrolls when *proposed* the capped height, yet still
/// has to be measured unconstrained to hug shorter content.
private struct CappedIdealHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let ideal = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

/// Theme chooser modelled on the Appearance control in System Settings: one
/// tappable preview per option instead of a row of words.
private struct ThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases) { theme in
                ThemeOption(
                    theme: theme,
                    isSelected: selection == theme,
                    select: { selection = theme }
                )
            }
        }
    }
}

private struct ThemeOption: View {
    let theme: AppTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                ThemePreview(theme: theme)
                Text(theme.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    // Without this the row's HStack can squeeze a label to
                    // zero width, wrapping it into blank lines that stretch
                    // that one option taller than its neighbours.
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(isSelected ? 0.15 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Keeps every available engine visible, following the same selection model
/// as the Appearance tabs above while leaving room for capability differences.
private struct TerminalBackendPicker: View {
    @Binding var selection: TerminalBackend

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(TerminalBackend.selectable) { backend in
                TerminalBackendOption(
                    backend: backend,
                    isSelected: selection == backend,
                    select: { selection = backend }
                )
            }
        }
        .frame(maxWidth: 310)
    }
}

private struct TerminalBackendOption: View {
    let backend: TerminalBackend
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(backend.settingsIconName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                    Text(backend.displayName)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(backend.settingsHighlights) { highlight in
                        TerminalBackendHighlightRow(highlight: highlight)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(isSelected ? 0.15 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(backend.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct TerminalBackendHighlightRow: View {
    let highlight: TerminalBackendHighlight

    var body: some View {
        let availability = highlight.isPositive
            ? String(localized: "Available", comment: "Accessibility description for a supported terminal feature.")
            : String(localized: "Unavailable", comment: "Accessibility description for an unsupported terminal feature.")
        HStack(spacing: 4) {
            Image(systemName: highlight.isPositive
                ? "checkmark.circle.fill"
                : "exclamationmark.circle.fill")
                .foregroundStyle(highlight.isPositive ? Color.green : Color.orange)
            Text(highlight.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                localized: "\(availability): \(highlight.title)",
                comment: "Accessibility label for a terminal feature and whether it is available."
            )
        )
    }
}

/// A miniature kero window painted in one appearance's real colors. `system`
/// splits down the middle — light on the left, dark on the right — the same
/// way System Settings previews "Auto".
private struct ThemePreview: View {
    let theme: AppTheme

    private static let size = CGSize(width: 76, height: 50)
    private static let corner: CGFloat = 7

    var body: some View {
        ZStack {
            switch theme {
            case .light:
                MiniWindow(dark: false)
            case .dark:
                MiniWindow(dark: true)
            case .system:
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: Self.size.width / 2)
                    }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// Sidebar, traffic lights, a tab, and a few lines of terminal output —
/// enough of kero's layout to read at thumbnail size.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let theme = Theme.terminal(dark: dark)
        let text = Color(nsColor: theme.foregroundNSColor)
        let cursor = Color(nsColor: theme.cursorNSColor)

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2.5) {
                    dot(0xFF5F57)
                    dot(0xFEBC2E)
                    dot(0x28C840)
                }
                .padding(.bottom, 3)

                bar(11, text.opacity(0.35))
                bar(8, text.opacity(0.35))
                bar(11, text.opacity(0.35))
            }
            .padding(5)
            .frame(minWidth: 22, maxWidth: 22, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: Theme.sidebarFill(dark: dark)))

            VStack(alignment: .leading, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(text.opacity(0.12))
                    .frame(width: 14, height: 5)
                    .padding(.bottom, 1)

                HStack(spacing: 2) {
                    bar(3, cursor)
                    bar(22, text.opacity(0.8))
                }
                bar(30, text.opacity(0.45))
                bar(16, text.opacity(0.45))
                HStack(spacing: 2) {
                    bar(3, cursor)
                    bar(7, text.opacity(0.8))
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: theme.backgroundNSColor))
        }
    }

    private func dot(_ hex: Int) -> some View {
        Circle()
            .fill(Color(
                .sRGB,
                red: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255
            ))
            .frame(width: 3.5, height: 3.5)
    }

    private func bar(_ width: CGFloat, _ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(fill)
            .frame(width: width, height: 2.5)
    }
}

#Preview {
    SettingsView()
}
