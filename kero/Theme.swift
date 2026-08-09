//
//  Theme.swift
//  kero
//

import AppKit
import Combine
import GhosttyTheme
import os

/// The user's light/dark preference. Applied by overriding `NSApp.appearance`,
/// which drives every window, the dynamic colors below, and — through
/// `NSApp.effectiveAppearance` — the terminal theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System", comment: "Appearance that follows the macOS setting.")
        case .light: return String(localized: "Light", comment: "Light app appearance.")
        case .dark: return String(localized: "Dark", comment: "Dark app appearance.")
        }
    }

    /// `nil` hands the appearance back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Publishes when the selected terminal themes change, so views painting with
/// `Theme` colors repaint without waiting for an appearance flip.
final class ThemeChanges: nonisolated ObservableObject {}

/// App colors, sourced from the ghostty themes the user selected in Settings
/// (one per appearance; GitHub Dark/Light Default out of the box). Terminal
/// sessions consume the definitions directly via `terminal(dark:)`; the
/// `NSColor` properties derive window chrome from the same palette and adapt
/// to the system appearance.
enum Theme {
    nonisolated static let defaultDarkThemeName = "Default Dark"
    nonisolated static let defaultLightThemeName = "Default Light"

    @MainActor static let changes = ThemeChanges()

    /// Kero's built-in themes: the GitHub Default palettes under kero's own
    /// names. Selecting one keeps the project sidebar's native translucent
    /// material (see `SidebarView`); picking the catalog originals — or any
    /// other theme — paints the flat theme shade instead.
    nonisolated static let defaultDarkDefinition = keroDefault(
        named: defaultDarkThemeName, from: "GitHub Dark Default", dark: true
    )
    nonisolated static let defaultLightDefinition = keroDefault(
        named: defaultLightThemeName, from: "GitHub Light Default", dark: false
    )

    /// Popular themes that render through the shared palette path used by both
    /// terminal backends. Each appearance has 29 catalog themes plus Kero's
    /// default, keeping either Settings picker capped at 30 choices.
    private nonisolated static let commonDarkCatalogThemeNames: Set<String> = [
        "Adwaita Dark",
        "Afterglow",
        "Atom One Dark",
        "Ayu",
        "Ayu Mirage",
        "Catppuccin Frappe",
        "Catppuccin Macchiato",
        "Catppuccin Mocha",
        "Dark+",
        "Dracula",
        "Everforest Dark Hard",
        "Flexoki Dark",
        "GitHub Dark",
        "GitHub Dark Dimmed",
        "Gruvbox Dark",
        "Gruvbox Material",
        "iTerm2 Solarized Dark",
        "Kanagawa Dragon",
        "Kanagawa Wave",
        "Material Dark",
        "Monokai Pro",
        "Night Owl",
        "Nord",
        "Nvim Dark",
        "Rose Pine",
        "Rose Pine Moon",
        "TokyoNight",
        "TokyoNight Storm",
        "Vesper",
    ]

    private nonisolated static let commonLightCatalogThemeNames: Set<String> = [
        "Adwaita",
        "Alabaster",
        "Apple System Colors Light",
        "Atom One Light",
        "Ayu Light",
        "Bluloco Light",
        "Catppuccin Latte",
        "Dawnfox",
        "Dayfox",
        "Everforest Light Med",
        "Flexoki Light",
        "GitHub",
        "GitHub Light High Contrast",
        "GitLab Light",
        "Gruvbox Light",
        "Gruvbox Material Light",
        "Iceberg Light",
        "iTerm2 Solarized Light",
        "Kanagawa Lotus",
        "Light Owl",
        "Material",
        "Modus Operandi",
        "Monokai Pro Light",
        "Nord Light",
        "Nvim Light",
        "One Half Light",
        "Rose Pine Dawn",
        "TokyoNight Day",
        "Tomorrow",
    ]

    /// Kero's Default comes first; the duplicate GitHub Default catalog rows
    /// are intentionally omitted because the built-ins use those palettes.
    nonisolated static let commonDarkThemes: [GhosttyThemeDefinition] =
        [defaultDarkDefinition] + GhosttyThemeCatalog.allThemes.filter {
            $0.isDark && commonDarkCatalogThemeNames.contains($0.name)
        }

    nonisolated static let commonLightThemes: [GhosttyThemeDefinition] =
        [defaultLightDefinition] + GhosttyThemeCatalog.allThemes.filter {
            !$0.isDark && commonLightCatalogThemeNames.contains($0.name)
        }

    nonisolated static func isCommonTheme(named name: String, dark: Bool) -> Bool {
        let themes = dark ? commonDarkThemes : commonLightThemes
        return themes.contains { $0.name == name }
    }

    /// The selected definitions, mirrored out of `AppSettings` because the
    /// dynamic color providers below may resolve outside the main actor.
    private nonisolated static let selection = OSAllocatedUnfairLock(
        initialState: (light: defaultLightDefinition, dark: defaultDarkDefinition)
    )

    /// A kero built-in or catalog theme by name.
    nonisolated static func definition(named name: String) -> GhosttyThemeDefinition? {
        if name == defaultLightThemeName { return defaultLightDefinition }
        if name == defaultDarkThemeName { return defaultDarkDefinition }
        return GhosttyThemeCatalog.theme(named: name)
    }

    /// Re-resolves the selected themes by name. Called by `AppSettings` on
    /// startup and whenever either terminal theme setting changes; unknown
    /// names keep the defaults.
    @MainActor
    static func reloadSelection(light: String, dark: String) {
        let resolved = (
            light: definition(named: light) ?? defaultLightDefinition,
            dark: definition(named: dark) ?? defaultDarkDefinition
        )
        selection.withLock { $0 = resolved }
        changes.objectWillChange.send()
    }

    /// Applies one catalog theme without changing the saved setting. The
    /// bundled `kero +themes` browser uses this while the user moves through
    /// its list, then either commits through `AppSettings` or restores the
    /// saved pair with `reloadSelection`.
    @MainActor
    @discardableResult
    static func previewSelection(named name: String, dark: Bool) -> Bool {
        guard isCommonTheme(named: name, dark: dark),
              let definition = definition(named: name)
        else { return false }
        selection.withLock {
            if dark {
                $0.dark = definition
            } else {
                $0.light = definition
            }
        }
        changes.objectWillChange.send()
        return true
    }

    /// The selected ghostty theme for one appearance.
    nonisolated static func terminal(dark: Bool) -> GhosttyThemeDefinition {
        selection.withLock { dark ? $0.dark : $0.light }
    }

    /// Whether the selected theme for one appearance is a kero built-in
    /// Default theme, which keeps the sidebar's translucent material.
    nonisolated static func isDefault(dark: Bool) -> Bool {
        terminal(dark: dark).isKeroDefault
    }

    /// A copy of a catalog theme under a kero-owned name.
    private nonisolated static func keroDefault(
        named name: String, from catalogName: String, dark: Bool
    ) -> GhosttyThemeDefinition {
        let base = fallback(named: catalogName, dark: dark)
        return GhosttyThemeDefinition(
            name: name,
            background: base.background,
            foreground: base.foreground,
            cursorColor: base.cursorColor,
            cursorText: base.cursorText,
            selectionBackground: base.selectionBackground,
            selectionForeground: base.selectionForeground,
            palette: base.palette
        )
    }

    static var background: NSColor { dynamic { $0.backgroundNSColor } }
    static var sidebar: NSColor { dynamic { $0.sidebarNSColor } }
    static var accent: NSColor { dynamic { $0.accentNSColor } }

    /// Hairline separators, derived from the theme's own palette so they
    /// stay visible even when a slot holds a theme that fights the
    /// appearance (say, a light background forced into the dark slot). The
    /// built-in Defaults keep the translucent label hairline the app shipped
    /// with — it reads correctly over their material sidebar.
    static var divider: NSColor {
        dynamic { theme in
            theme.isKeroDefault
                ? NSColor.labelColor.withAlphaComponent(0.06)
                : theme.surfaceNSColor(elevation: 0.08)
        }
    }

    /// Sidebar fill resolved for one appearance. The Settings theme previews
    /// draw light and dark side by side, so they can't use the dynamic
    /// `sidebar` — it would resolve both halves to the ambient appearance.
    static func sidebarFill(dark: Bool) -> NSColor {
        terminal(dark: dark).sidebarNSColor
    }

    /// A fresh dynamic color per access: cached instances keep resolving the
    /// theme they were created under, so views re-rendered after a selection
    /// change would repaint with stale colors.
    private nonisolated static func dynamic(
        _ resolve: @escaping @Sendable (GhosttyThemeDefinition) -> NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolve(terminal(dark: isDark))
        }
    }

    /// Last-resort definition should a default name ever leave the catalog.
    private nonisolated static func fallback(named name: String, dark: Bool) -> GhosttyThemeDefinition {
        GhosttyThemeCatalog.theme(named: name) ?? GhosttyThemeDefinition(
            name: name,
            background: dark ? "0d1117" : "ffffff",
            foreground: dark ? "e6edf3" : "1f2328"
        )
    }
}

/// UI-facing colors for a ghostty theme definition. The definition stores
/// terminal colors as hex strings; window chrome derives its palette here.
/// Nonisolated so the dynamic color providers can resolve on any thread.
nonisolated extension GhosttyThemeDefinition {
    /// Whether this is one of kero's built-in Default themes, which keep the
    /// pre-theme chrome (material sidebar, label-based hairlines).
    var isKeroDefault: Bool {
        name == Theme.defaultDarkThemeName || name == Theme.defaultLightThemeName
    }

    var backgroundNSColor: NSColor { Self.nsColor(background) }
    var foregroundNSColor: NSColor { Self.nsColor(foreground) }

    var cursorNSColor: NSColor {
        cursorColor.map(Self.nsColor) ?? accentNSColor
    }

    /// Accent for selection highlights, focus rings, and active icons: ANSI
    /// blue reads as a theme's "link" color, with the cursor color, then the
    /// foreground, as fallbacks for palettes that don't define one.
    var accentNSColor: NSColor {
        (palette[4] ?? cursorColor).map(Self.nsColor) ?? foregroundNSColor
    }

    /// Sidebar fill: kero's built-in Default themes keep the GitHub
    /// canvas-inset shades the app shipped with; every other theme uses its
    /// own background so the sidebars blend with the rest of the window —
    /// a derived darker shade reads as broken for themes whose background
    /// isn't already near-black.
    var sidebarNSColor: NSColor {
        if name == Theme.defaultDarkThemeName { return Self.nsColor("010409") }
        if name == Theme.defaultLightThemeName { return Self.nsColor("f6f8fa") }
        return backgroundNSColor
    }

    /// `background` blended toward `foreground`; used for the editor's line
    /// highlight and gutter shades.
    func surfaceNSColor(elevation: CGFloat) -> NSColor {
        backgroundNSColor.blended(withFraction: elevation, of: foregroundNSColor)
            ?? backgroundNSColor
    }

    private static func nsColor(_ hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return .magenta // Unmistakable flag for a malformed catalog entry.
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }
}
