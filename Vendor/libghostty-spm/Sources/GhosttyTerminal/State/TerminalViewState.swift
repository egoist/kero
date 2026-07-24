//
//  TerminalViewState.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import SwiftUI

@MainActor
public final class TerminalViewState: ObservableObject {
    @Published public internal(set) var title: String = ""
    @Published public internal(set) var surfaceSize: TerminalGridMetrics?
    @Published public internal(set) var isFocused: Bool = false

    @Published public internal(set) var bellCount: Int = 0
    @Published public internal(set) var lastBellAt: Date?

    @Published public internal(set) var lastDesktopNotificationTitle: String?
    @Published public internal(set) var lastDesktopNotificationBody: String?
    @Published public internal(set) var lastDesktopNotificationAt: Date?

    @Published public internal(set) var workingDirectory: String?

    @Published public internal(set) var lastCommandExitCode: Int?
    @Published public internal(set) var lastCommandDurationNanos: UInt64?

    /// Latest scrollbar geometry reported by the terminal (nil until the first
    /// update). Drives a host-drawn scrollbar.
    @Published public internal(set) var scrollbar: TerminalScrollbar?

    public internal(set) weak var surface: TerminalSurface?

    @Published public var configuration: TerminalSurfaceOptions = .init()
    public var onClose: ((Bool) -> Void)?
    @Published public internal(set) var controller: TerminalController

    /// Sends text to the attached surface.
    @discardableResult
    public func send(_ text: String) -> Bool {
        guard let surface else {
            TerminalDebugLog.log(.input, "view state send ignored: missing surface")
            return false
        }
        return surface.sendText(text)
    }

    /// Invoke a named Ghostty binding action on the attached surface.
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        surface?.performBindingAction(action) ?? false
    }

    /// Jump the viewport by a number of shell prompts.
    ///
    /// Negative offsets move toward older prompts and positive offsets move
    /// toward newer prompts. Prompt navigation requires shell integration.
    @discardableResult
    public func jumpToPrompt(by offset: Int16) -> Bool {
        surface?.jumpToPrompt(by: offset) ?? false
    }

    /// Reveal an absolute scrollback row, where zero is the first row.
    @discardableResult
    public func scrollToRow(_ row: UInt) -> Bool {
        surface?.scrollToRow(row) ?? false
    }

    public convenience init() {
        self.init(configSource: .none)
    }

    public convenience init(configFilePath: String?) {
        if let configFilePath {
            self.init(configSource: .file(configFilePath))
        } else {
            self.init(configSource: .none)
        }
    }

    public init(
        configSource: TerminalController.ConfigSource = .none,
        theme: TerminalTheme = .default,
        terminalConfiguration: TerminalConfiguration = .init()
    ) {
        controller = TerminalController(
            configSource: configSource,
            theme: theme,
            terminalConfiguration: terminalConfiguration
        )
    }

    public init(controller: TerminalController) {
        self.controller = controller
    }

    // MARK: - Forwarded from Controller (single source of truth)

    public var renderedConfig: String {
        controller.renderedConfig
    }

    public var effectiveColorScheme: TerminalColorScheme {
        controller.effectiveColorScheme
    }

    public var theme: TerminalTheme {
        controller.theme
    }

    public var terminalConfiguration: TerminalConfiguration {
        controller.terminalConfiguration
    }
}
