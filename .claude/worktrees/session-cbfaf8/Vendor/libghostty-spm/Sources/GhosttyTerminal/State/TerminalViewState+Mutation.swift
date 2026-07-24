//
//  TerminalViewState+Mutation.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

import SwiftUI

public extension TerminalViewState {
    func adopt(colorScheme: ColorScheme) {
        adopt(terminalColorScheme: TerminalColorScheme(colorScheme))
    }

    func adopt(terminalColorScheme colorScheme: TerminalColorScheme) {
        guard colorScheme != controller.effectiveColorScheme else { return }
        controller.setColorScheme(colorScheme) {
            self.objectWillChange.send()
        }
    }

    @discardableResult
    func setTheme(_ theme: TerminalTheme) -> Bool {
        return controller.setTheme(theme) {
            self.objectWillChange.send()
        }
    }

    @discardableResult
    func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration
    ) -> Bool {
        return controller.setTerminalConfiguration(terminalConfiguration) {
            self.objectWillChange.send()
        }
    }
}
