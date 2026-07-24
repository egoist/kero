//
//  GhosttyThemeDefinition.swift
//  libghostty-spm
//

public struct GhosttyThemeDefinition: Sendable, Hashable, Identifiable {
    public var id: String {
        name
    }

    public let name: String
    public let background: String
    public let foreground: String
    public let cursorColor: String?
    public let cursorText: String?
    public let selectionBackground: String?
    public let selectionForeground: String?
    public let palette: [Int: String]

    public init(
        name: String,
        background: String,
        foreground: String,
        cursorColor: String? = nil,
        cursorText: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [Int: String] = [:]
    ) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }
}
