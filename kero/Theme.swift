//
//  Theme.swift
//  kero
//

import AppKit

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
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
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

/// Colors a terminal session needs, resolved for one appearance.
struct KeroTerminalTheme {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    /// The 16 ANSI colors (normal, then bright) as `RRGGBB` strings.
    let ansi: [String]
}

/// App theme, loosely based on GitHub Dark / GitHub Light.
/// The `NSColor` properties are dynamic and adapt to the system appearance;
/// terminal sessions use `terminal(dark:)` and re-apply on appearance change.
enum Theme {
    static let background = dynamic(light: 0xffffff, dark: 0x0d1117)
    static let sidebar = dynamic(light: sidebarLight, dark: sidebarDark)
    static let cursor = dynamic(light: 0x0969da, dark: 0x58a6ff)

    private static let sidebarLight = 0xf6f8fa
    private static let sidebarDark = 0x010409

    /// Sidebar fill resolved for one appearance. The Settings theme previews
    /// draw light and dark side by side, so they can't use the dynamic
    /// `sidebar` — it would resolve both halves to the ambient appearance.
    static func sidebarFill(dark: Bool) -> NSColor {
        nsColor(dark ? sidebarDark : sidebarLight)
    }

    static func terminal(dark: Bool) -> KeroTerminalTheme {
        dark
            ? KeroTerminalTheme(
                background: nsColor(0x0d1117),
                foreground: nsColor(0xe6edf3),
                cursor: nsColor(0x58a6ff),
                ansi: darkAnsi
            )
            : KeroTerminalTheme(
                background: nsColor(0xffffff),
                foreground: nsColor(0x1f2328),
                cursor: nsColor(0x0969da),
                ansi: lightAnsi
            )
    }

    /// The 16 ANSI colors (normal + bright), dark variant.
    private static let darkAnsi: [String] = [
        ansi(0x21262d), // black
        ansi(0xff7b72), // red
        ansi(0x3fb950), // green
        ansi(0xd29922), // yellow
        ansi(0x58a6ff), // blue
        ansi(0xbc8cff), // magenta
        ansi(0x39c5cf), // cyan
        ansi(0xb1bac4), // white
        ansi(0x484f58), // bright black
        ansi(0xffa198), // bright red
        ansi(0x56d364), // bright green
        ansi(0xe3b341), // bright yellow
        ansi(0x79c0ff), // bright blue
        ansi(0xd2a8ff), // bright magenta
        ansi(0x56d4dd), // bright cyan
        ansi(0xf0f6fc), // bright white
    ]

    /// The 16 ANSI colors (normal + bright), light variant.
    private static let lightAnsi: [String] = [
        ansi(0x24292f), // black
        ansi(0xcf222e), // red
        ansi(0x116329), // green
        ansi(0x953800), // yellow
        ansi(0x0969da), // blue
        ansi(0x8250df), // magenta
        ansi(0x1b7c83), // cyan
        ansi(0x6e7781), // white
        ansi(0x57606a), // bright black
        ansi(0xa40e26), // bright red
        ansi(0x1a7f37), // bright green
        ansi(0x633c01), // bright yellow
        ansi(0x218bff), // bright blue
        ansi(0xa475f9), // bright magenta
        ansi(0x3192aa), // bright cyan
        ansi(0x8c959f), // bright white
    ]

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        }
    }

    private static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: 1
        )
    }

    static func hex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    private static func ansi(_ hex: Int) -> String {
        String(format: "%06X", hex)
    }
}
