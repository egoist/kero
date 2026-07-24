//
//  TerminalColorScheme+SwiftUI.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(SwiftUI)
    import SwiftUI

    extension TerminalColorScheme {
        init(_ colorScheme: ColorScheme) {
            switch colorScheme {
            case .dark:
                self = .dark
            default:
                self = .light
            }
        }
    }
#endif
