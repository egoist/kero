//
//  TerminalTheme.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

public struct TerminalTheme: Sendable, Hashable {
    public var light: TerminalConfiguration
    public var dark: TerminalConfiguration

    public init(
        light: TerminalConfiguration = .init(),
        dark: TerminalConfiguration = .init()
    ) {
        self.light = light
        self.dark = dark
    }

    var isEmpty: Bool {
        light.isEmpty && dark.isEmpty
    }

    func configuration(for colorScheme: TerminalColorScheme) -> TerminalConfiguration {
        switch colorScheme {
        case .light:
            light
        case .dark:
            dark
        }
    }
}
