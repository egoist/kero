//
//  GhosttyConfigRenderer.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

import Foundation

enum GhosttyConfigRenderer {
    static func render(
        baseContents: String,
        configuration: TerminalConfiguration,
        theme: TerminalConfiguration
    ) -> String {
        var sections: [String] = []

        let normalizedBase = normalize(baseContents)
        if !normalizedBase.isEmpty {
            sections.append(normalizedBase)
        }

        let configurationLines = configuration.commands.map(\.renderedLine)
        if !configurationLines.isEmpty {
            sections.append(configurationLines.joined(separator: "\n"))
        }

        let themeLines = theme.commands.map(\.renderedLine)
        if !themeLines.isEmpty {
            sections.append(themeLines.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n") + "\n"
    }

    private static func normalize(_ contents: String) -> String {
        contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
