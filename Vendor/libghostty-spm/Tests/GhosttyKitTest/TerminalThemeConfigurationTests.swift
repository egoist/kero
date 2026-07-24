@testable import GhosttyTerminal
import Combine
import SwiftUI
import Testing

@MainActor
struct TerminalThemeConfigurationTests {
    @Test
    func `command builder preserves insertion order`() {
        let configuration = TerminalConfiguration {
            $0.withFontSize(13)
            $0.withCursorStyle(.bar)
            $0.withCursorStyleBlink(false)
            $0.withBackground("#101010")
        }

        #expect(
            configuration.rendered
                == """
                font-size = 13
                cursor-style = bar
                cursor-style-blink = false
                background = #101010
                """
        )
    }

    @Test
    func `rendered config composes base behavior and theme`() {
        let state = TerminalViewState(
            configSource: .generated(
                """
                font-size = 14
                cursor-style = block
                """
            ),
            theme: .init(
                light: TerminalConfiguration()
                    .backgroundOpacity(0.82)
                    .background("#111111"),
                dark: TerminalConfiguration()
                    .backgroundOpacity(0.62)
                    .background("#000000")
            ),
            terminalConfiguration: TerminalConfiguration()
                .cursorStyleBlink(true)
        )

        #expect(state.renderedConfig.contains("font-size = 14"))
        #expect(state.renderedConfig.contains("cursor-style = block"))
        #expect(state.renderedConfig.contains("cursor-style-blink = true"))
        #expect(state.renderedConfig.contains("background-opacity = 0.82"))
        #expect(state.renderedConfig.contains("background = #111111"))
    }

    @Test
    func `valid configuration update preserves controller identity`() {
        let state = TerminalViewState(
            terminalConfiguration: TerminalConfiguration()
                .fontSize(14)
        )
        let controller = state.controller

        let didApply = state.setTerminalConfiguration(
            TerminalConfiguration()
                .fontSize(16)
                .cursorStyle(.underline)
        )

        #expect(didApply)
        #expect(state.controller === controller)
        #expect(state.terminalConfiguration == TerminalConfiguration()
            .fontSize(16)
            .cursorStyle(.underline))
        #expect(state.renderedConfig.contains("font-size = 16"))
        #expect(state.renderedConfig.contains("cursor-style = underline"))
        let fontSizeLines = state.renderedConfig
            .split(separator: "\n")
            .filter { $0.hasPrefix("font-size = ") }
        #expect(fontSizeLines.last == "font-size = 16")
    }

    @Test
    func `adopting dark mode switches rendered theme variant`() {
        let state = TerminalViewState(
            theme: .init(
                light: TerminalConfiguration()
                    .backgroundOpacity(0.91),
                dark: TerminalConfiguration()
                    .backgroundOpacity(0.47)
            )
        )
        var notificationCount = 0
        var colorSchemeAtNotification: TerminalColorScheme?
        let cancellable = state.objectWillChange.sink {
            notificationCount += 1
            colorSchemeAtNotification = state.effectiveColorScheme
        }
        defer { cancellable.cancel() }
        let controller = state.controller

        #expect(state.effectiveColorScheme == .light)
        #expect(state.renderedConfig.contains("background-opacity = 0.91"))

        state.adopt(colorScheme: .dark)

        #expect(notificationCount == 1)
        #expect(colorSchemeAtNotification == .light)
        #expect(state.effectiveColorScheme == .dark)
        #expect(state.renderedConfig.contains("background-opacity = 0.47"))
        #expect(!state.renderedConfig.contains("background-opacity = 0.91"))
        #expect(state.controller === controller)
    }

    @Test
    func `invalid dark theme rolls back color scheme and rendered config`() {
        let state = TerminalViewState(
            theme: .init(
                light: TerminalConfiguration()
                    .backgroundOpacity(0.91),
                dark: TerminalConfiguration()
                    .custom("not-a-real-ghostty-option", "true")
            )
        )
        var notificationCount = 0
        let cancellable = state.objectWillChange.sink {
            notificationCount += 1
        }
        defer { cancellable.cancel() }
        let previousRenderedConfig = state.renderedConfig

        state.adopt(colorScheme: .dark)

        // Controller rolls back on config failure, so color scheme stays light
        #expect(notificationCount == 0)
        #expect(state.effectiveColorScheme == .light)
        #expect(state.renderedConfig == previousRenderedConfig)
        #expect(state.renderedConfig.contains("background-opacity = 0.91"))
    }

    @Test
    func `adopting current color scheme does not notify`() {
        let state = TerminalViewState()
        var notificationCount = 0
        let cancellable = state.objectWillChange.sink {
            notificationCount += 1
        }
        defer { cancellable.cancel() }

        #expect(state.effectiveColorScheme == .light)
        state.adopt(colorScheme: .light)

        #expect(notificationCount == 0)
        #expect(state.effectiveColorScheme == .light)
    }

    @Test
    func `shared controller accepts mutations`() {
        let controller = TerminalController()
        let state = TerminalViewState(controller: controller)

        // With the single-source-of-truth architecture, mutations go
        // directly to the controller and succeed.
        let didSetTheme = state.setTheme(
            .init(
                light: TerminalConfiguration()
                    .backgroundOpacity(0.5)
            )
        )

        #expect(didSetTheme)
        #expect(state.controller === controller)
        #expect(state.renderedConfig.contains("background-opacity = 0.5"))
    }

    @Test
    func `no op theme update returns false`() {
        let theme = TerminalTheme(
            light: TerminalConfiguration()
                .backgroundOpacity(0.7)
        )
        let state = TerminalViewState(theme: theme)
        var notificationCount = 0
        let cancellable = state.objectWillChange.sink {
            notificationCount += 1
        }
        defer { cancellable.cancel() }
        let previousRenderedConfig = state.renderedConfig

        let didApply = state.setTheme(theme)

        #expect(!didApply)
        #expect(notificationCount == 0)
        #expect(state.renderedConfig == previousRenderedConfig)
    }

    @Test
    func `invalid configuration does not replace rendered config`() {
        let state = TerminalViewState(
            terminalConfiguration: TerminalConfiguration()
                .fontSize(14)
        )
        var notificationCount = 0
        let cancellable = state.objectWillChange.sink {
            notificationCount += 1
        }
        defer { cancellable.cancel() }
        let previousRenderedConfig = state.renderedConfig

        let didApply = state.setTerminalConfiguration(
            TerminalConfiguration()
                .custom("not-a-real-ghostty-option", "true")
        )

        #expect(!didApply)
        #expect(notificationCount == 0)
        #expect(state.renderedConfig == previousRenderedConfig)
        #expect(state.terminalConfiguration == TerminalConfiguration().fontSize(14))
    }
}
