//
//  TerminalTheme+Defaults.swift
//  libghostty-spm
//

public extension TerminalTheme {
    /// Afterglow (dark) + Alabaster (light) default theme.
    static let `default` = TerminalTheme(
        light: .alabaster,
        dark: .afterglow
    )
}

public extension TerminalConfiguration {
    /// Alabaster — light terminal theme.
    ///
    /// Background: #F7F7F7, Foreground: #000000
    static let alabaster = TerminalConfiguration { builder in
        builder.withBackground("F7F7F7")
        builder.withForeground("000000")
        builder.withCursorColor("007ACC")
        builder.withSelectionBackground("C9D0D9")
        // Normal colors (0-7)
        builder.withPalette(0, color: "#000000")
        builder.withPalette(1, color: "#AA3731")
        builder.withPalette(2, color: "#448C27")
        builder.withPalette(3, color: "#CB8800")
        builder.withPalette(4, color: "#325CC0")
        builder.withPalette(5, color: "#7A3E9D")
        builder.withPalette(6, color: "#0083B2")
        builder.withPalette(7, color: "#F7F7F7")
        // Bright colors (8-15)
        builder.withPalette(8, color: "#777777")
        builder.withPalette(9, color: "#F03E31")
        builder.withPalette(10, color: "#60CB00")
        builder.withPalette(11, color: "#FFBC5D")
        builder.withPalette(12, color: "#007ACC")
        builder.withPalette(13, color: "#E64CE6")
        builder.withPalette(14, color: "#00AACB")
        builder.withPalette(15, color: "#F7F7F7")
    }

    /// Afterglow — dark terminal theme.
    ///
    /// Background: #212121, Foreground: #D0D0D0
    static let afterglow = TerminalConfiguration { builder in
        builder.withBackground("212121")
        builder.withForeground("D0D0D0")
        builder.withCursorColor("D0D0D0")
        builder.withSelectionBackground("303030")
        // Normal colors (0-7)
        builder.withPalette(0, color: "#151515")
        builder.withPalette(1, color: "#AC4142")
        builder.withPalette(2, color: "#7E8E50")
        builder.withPalette(3, color: "#E4B567")
        builder.withPalette(4, color: "#6C99BB")
        builder.withPalette(5, color: "#9F4E86")
        builder.withPalette(6, color: "#7DD5CF")
        builder.withPalette(7, color: "#D0D0D0")
        // Bright colors (8-15)
        builder.withPalette(8, color: "#505050")
        builder.withPalette(9, color: "#AC4142")
        builder.withPalette(10, color: "#7E8E50")
        builder.withPalette(11, color: "#E4B567")
        builder.withPalette(12, color: "#6C99BB")
        builder.withPalette(13, color: "#9F4E86")
        builder.withPalette(14, color: "#7DD5CF")
        builder.withPalette(15, color: "#F5F5F5")
    }
}
