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

    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()

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
                // SwiftUI Text cannot show Ghostty's font-thicken — that flag
                // only affects CoreText glyph rasterization — so draw through
                // AppKit with shouldSmoothFonts matching the toggle.
                FontThickenPreview(font: previewFont, thicken: settings.fontThicken)
                    .padding(.vertical, 4)
                    // NSView drawing has no semantic children of its own.
                    // Preserve the sample text that the previous SwiftUI Text
                    // views exposed to VoiceOver.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: """
                    kero ❯ echo "the quick brown fox" 0O 1lI
                    \u{E0A0} main \u{E0B0} ~/dev/kero \u{E711} \u{F024B} \u{F0A7D}
                    bold — permission denied (os error 13)
                    """))
                    .accessibilityAddTraits(.isStaticText)
            }

            Section("Terminal") {
                // Only show this once there is a real choice. `selectable`
                // omits backends this build cannot create, so every tab here
                // takes effect instead of silently producing a dead pane.
                if TerminalBackend.selectable.count > 1 {
                    HStack(alignment: .top) {
                        Text("Backend")
                        Spacer()
                        VStack(alignment: .leading, spacing: 8) {
                            TerminalBackendPicker(selection: $settings.terminalBackend)
                            Text("Changes apply to new terminals.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
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
                        && settings.terminalBackend == .fallback)
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

/// Settings font preview that honors `font-thicken`. Ghostty thickens by
/// enabling CoreText font smoothing when rasterizing glyphs; SwiftUI `Text`
/// does not, so toggling the setting left this preview unchanged.
private struct FontThickenPreview: NSViewRepresentable {
    var font: NSFont
    var thicken: Bool

    func makeNSView(context: Context) -> FontThickenPreviewView {
        FontThickenPreviewView()
    }

    func updateNSView(_ view: FontThickenPreviewView, context: Context) {
        view.previewFont = font
        view.thicken = thicken
        view.needsDisplay = true
        view.invalidateIntrinsicContentSize()
    }
}

private final class FontThickenPreviewView: NSView {
    var previewFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var thicken = false

    /// Regular / icon / bold lines — same samples as the old SwiftUI preview.
    private let lines: [(text: String, bold: Bool)] = [
        ("kero ❯ echo \"the quick brown fox\" 0O 1lI", false),
        ("\u{E0A0} main \u{E0B0} ~/dev/kero \u{E711} \u{F024B} \u{F0A7D}", false),
        ("bold — permission denied (os error 13)", true),
    ]

    private let lineSpacing: CGFloat = 6
    private let verticalPadding: CGFloat = 4

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        let height = verticalPadding * 2
            + CGFloat(lines.count) * lineHeight
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Mirror Ghostty's CoreText glyph path (face/coretext.zig):
        // font-thicken == shouldSmoothFonts.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(thicken)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let color = NSColor.labelColor
        var y = verticalPadding
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        for (text, bold) in lines {
            let font = bold
                ? NSFontManager.shared.convert(previewFont, toHaveTrait: .boldFontMask)
                : previewFont
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
            y += lineHeight + lineSpacing
        }
    }
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
