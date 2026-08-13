//
//  AgentAutomation.swift
//  kero
//

import AppKit
import Foundation

enum KeroAgentKind: String, CaseIterable, Codable, Sendable {
    case codex
    case claude
    case gemini
    case grok
    case opencode
    case cursor = "cursor-agent"
    case aider
    case amp
    case pi

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .grok: return "Grok Build"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor Agent"
        case .aider: return "Aider"
        case .amp: return "Amp"
        case .pi: return "Pi"
        }
    }

    var executable: String { rawValue }

    static func recognize(processID: pid_t) -> Self? {
        recognize(
            executablePath: processExecutablePath(pid: processID),
            arguments: processArguments(pid: processID) ?? []
        )
    }

    static func recognize(
        executablePath: String?,
        arguments: [String] = []
    ) -> Self? {
        // argv[0] preserves the invoked symlink for versioned native installs
        // such as Claude and `exec -a` wrappers such as Cursor Agent.
        for value in [arguments.first, executablePath].compactMap({ $0 }) {
            if let kind = recognizeCommandName(value) { return kind }
        }

        guard let executablePath,
              isScriptInterpreter((executablePath as NSString).lastPathComponent)
        else { return nil }

        let tail = Array(arguments.dropFirst().prefix(8))
        if let moduleFlag = tail.firstIndex(of: "-m"),
           tail.indices.contains(moduleFlag + 1),
           let kind = recognizeScriptIdentity(tail[moduleFlag + 1]) {
            return kind
        }

        // For the supported wrappers the first non-option operand identifies
        // the script. Stop there rather than scanning prompts or user paths,
        // which would make ordinary interpreter jobs look like agents.
        for value in tail {
            if value.hasPrefix("-") || value == "run" { continue }
            return recognizeScriptIdentity(value)
        }
        return nil
    }

    private static func recognizeCommandName(_ value: String) -> Self? {
        var name = (value as NSString).lastPathComponent.lowercased()
        for suffix in [".exe", ".js", ".mjs", ".cjs", ".py"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        if name == "grok" || name == "xai-grok-pager" {
            return .grok
        }
        // Official installs resolve `~/.grok/bin/grok` to a versioned binary
        // such as `grok-1.0.0-macos-aarch64`; foreground PID inspection sees
        // that target even though argv[0] usually preserves the `grok` link.
        if name.hasPrefix("grok-"),
           name.contains("-macos-") || name.contains("-linux-") {
            return .grok
        }
        switch name {
        case "codex": return .codex
        case "claude": return .claude
        case "gemini": return .gemini
        case "opencode": return .opencode
        case "cursor-agent": return .cursor
        case "aider", "aider-chat": return .aider
        case "amp": return .amp
        case "pi": return .pi
        default: return nil
        }
    }

    private static func isScriptInterpreter(_ value: String) -> Bool {
        let name = value.lowercased()
        return name == "node" || name == "nodejs" || name == "bun"
            || name == "deno" || name == "python" || name.hasPrefix("python3")
            || name == "ruby" || name == "bash" || name == "sh" || name == "zsh"
    }

    private static func recognizeScriptIdentity(_ value: String) -> Self? {
        if let kind = recognizeCommandName(value) { return kind }
        let normalized = value.lowercased().replacingOccurrences(of: "\\", with: "/")
        if normalized.contains("/@openai/codex/") { return .codex }
        if normalized.contains("/@anthropic-ai/claude-code/") { return .claude }
        if normalized.contains("/gemini-cli/") { return .gemini }
        if normalized.contains("/grok-dev/") { return .grok }
        if normalized.contains("/opencode-ai/") { return .opencode }
        if normalized.contains("/cursor-agent/") { return .cursor }
        if normalized.contains("/aider-chat/") || normalized.contains("/aider_chat/") {
            return .aider
        }
        if normalized.contains("/sourcegraph/amp/") { return .amp }
        if normalized.contains("/pi-coding-agent/") { return .pi }
        return nil
    }
}

enum KeroAgentPhase: String, Codable, CaseIterable, Sendable {
    case created
    case working
    case blocked
    case done
    case idle
    case unknown

    fileprivate var rollupPriority: Int {
        switch self {
        case .blocked: return 6
        case .done: return 5
        case .working: return 4
        case .unknown: return 3
        case .created: return 2
        case .idle: return 1
        }
    }
}

enum KeroAgentStateAuthority: String, Codable, Sendable {
    /// A native agent hook or plugin reported a complete lifecycle event.
    case integration
    /// Kero recognized the foreground executable.
    case process
    /// Kero just launched or prompted the agent and is awaiting a lifecycle event.
    case command
}

struct KeroAgentStatus: Equatable, Sendable {
    let alias: String
    let kind: KeroAgentKind
    let phase: KeroAgentPhase
    let authority: KeroAgentStateAuthority
    let reason: String
    let updatedAt: Date
    let processID: pid_t?
    /// Completion remains unseen until the pane itself receives focus. Reads
    /// through the automation API deliberately do not mutate this bit.
    let unseen: Bool
}

struct KeroAgentRollup: Equatable {
    let phase: KeroAgentPhase
    let count: Int
}

enum KeroAutomationReadError: Error {
    case agentNotIdle
}

/// Mutable evidence kept beside a `TerminalSession`. It is separate from the
/// published status so unchanged polling never invalidates AppKit/SwiftUI view
/// trees.
@MainActor
final class KeroAgentObservationState {
    var declaredKind: KeroAgentKind?
    var alias: String?
    var lastForegroundPID: pid_t?
    var integrationPhase: KeroAgentPhase?
    var integrationReason: String?
    /// Native integrations publish semantic idle, not whether that idle ended
    /// a turn. Track active-turn evidence so launching an already-idle CLI in
    /// the background never looks like a newly finished task.
    var integrationTurnActive = false
    var isCollectingAlternateScreenHistory = false
    /// A Kero-launched process is `created` until its first guarded prompt.
    /// This lifecycle fact does not require guessing how the CLI renders UI.
    var awaitingInitialPrompt = false
    /// Shell input is asynchronous. Keep a freshly declared launch working
    /// briefly so the monitor cannot mistake the still-foreground shell for
    /// an agent that already exited before it has consumed the command.
    var commandGraceDeadline: Date?
}

@MainActor
final class AgentAutomationMonitor {
    static let shared = AgentAutomationMonitor()

    private let sessions = NSHashTable<TerminalSession>.weakObjects()
    private var timer: Timer?

    private init() {}

    func register(_ session: TerminalSession) {
        sessions.add(session)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let liveSessions = sessions.allObjects.filter { !$0.hasExited }
        for session in liveSessions {
            session.refreshAutomationAgentState(
                isFocused: TerminalManager.automationIsSessionFocused(session.id)
            )
        }
        if liveSessions.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

extension TerminalSession {
    var isShellAvailableForAutomation: Bool {
        guard !hasExited, let shellPid, shellPid > 0 else { return false }
        return surface.foregroundPid == shellPid
            && commandLifecycle.phase != .executing
    }

    func isAutomationAgentRunning(kind: KeroAgentKind) -> Bool {
        guard let foreground = surface.foregroundPid,
              foreground != shellPid else { return false }
        return KeroAgentKind.recognize(processID: foreground) == kind
    }

    /// Bounded viewport text for automation reads and diagnostics. Reading
    /// does not call `markAutomationAgentSeen()`.
    func automationVisibleText(maxLines: Int, maxColumns: Int) -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        guard let text = surface.readVisibleText(
            maxLines: boundedLines, maxColumns: boundedColumns
        ) else { return "" }
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.prefix(boundedColumns)) }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(boundedLines).joined(separator: "\n")
    }

    /// Recent host history for automation result reads. Unlike lifecycle
    /// detection, this deliberately asks the backend for bounded scrollback.
    func automationRecentText(maxLines: Int, maxColumns: Int) -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        return TerminalHistorySerializer.previewText(
            from: surface,
            maxLines: boundedLines,
            maxColumns: boundedColumns
        ) ?? automationVisibleText(
            maxLines: boundedLines,
            maxColumns: boundedColumns
        )
    }

    /// Collects older transcript pages from an idle full-screen agent when its
    /// alternate buffer has no host scrollback. Every page overlaps the prior
    /// page, and the same wheel interface is driven back to the live bottom
    /// before the read completes. Unsupported applications simply return the
    /// passive recent snapshot after the first wheel event changes nothing.
    func automationReadText(
        maxLines: Int,
        maxColumns: Int,
        requireIdleAgentForHistory: Bool
    ) async throws -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        let recent = automationRecentText(
            maxLines: boundedLines,
            maxColumns: boundedColumns
        )
        let recentLines = Self.automationLines(recent)
        guard recentLines.count < boundedLines,
              !TerminalHistorySerializer.hasPrimaryScrollback(surface),
              terminalIsAtLiveBottom,
              let status = agentStatus,
              isAutomationAgentRunning(kind: status.kind),
              !agentObservation.isCollectingAlternateScreenHistory
        else { return recent }

        guard status.phase == .idle || status.phase == .done else {
            if requireIdleAgentForHistory { throw KeroAutomationReadError.agentNotIdle }
            return recent
        }

        var latestPage = Self.automationLines(
            automationVisibleText(
                maxLines: boundedLines,
                maxColumns: boundedColumns
            )
        )
        guard !latestPage.isEmpty else { return recent }

        var collected = latestPage
        let pageStep = min(max(latestPage.count - 4, 4), 50)
        var pagesMoved = 0
        agentObservation.isCollectingAlternateScreenHistory = true
        defer { agentObservation.isCollectingAlternateScreenHistory = false }

        while collected.count < boundedLines, pagesMoved < 32 {
            guard surface.sendApplicationScroll(lines: pageStep) else { break }
            pagesMoved += 1
            try? await Task.sleep(for: .milliseconds(90))

            let olderPage = Self.automationLines(
                automationVisibleText(
                    maxLines: boundedLines,
                    maxColumns: boundedColumns
                )
            )
            guard !olderPage.isEmpty, olderPage != latestPage else { break }
            let merged = Self.prependingAutomationPage(
                olderPage,
                previousPage: latestPage,
                collected: collected
            )
            guard merged != collected else { break }
            collected = merged
            latestPage = olderPage
        }

        if pagesMoved > 0 {
            // Each downward batch is at least as large as the upward page step;
            // two extra batches cover applications that clamp one wheel burst.
            for _ in 0..<(pagesMoved + 2) {
                guard surface.sendApplicationScroll(lines: -50) else { break }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        return collected.suffix(boundedLines).joined(separator: "\n")
    }

    private static func automationLines(_ text: String) -> [String] {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func prependingAutomationPage(
        _ olderPage: [String],
        previousPage: [String],
        collected: [String]
    ) -> [String] {
        var olderContent = olderPage

        // Full-screen agents often pin an input/status footer while their
        // transcript scrolls. Drop one copy before looking for page overlap.
        let maximumFooter = min(8, min(olderPage.count, previousPage.count))
        var sharedFooter = 0
        if maximumFooter > 0 {
            for count in stride(from: maximumFooter, through: 1, by: -1)
            where Array(olderPage.suffix(count)) == Array(previousPage.suffix(count)) {
                sharedFooter = count
                break
            }
        }
        if sharedFooter > 0 { olderContent.removeLast(sharedFooter) }
        guard !olderContent.isEmpty else { return collected }

        let maximumOverlap = min(olderContent.count, collected.count)
        var overlap = 0
        if maximumOverlap > 0 {
            for count in stride(from: maximumOverlap, through: 1, by: -1)
            where Array(olderContent.suffix(count)) == Array(collected.prefix(count)) {
                overlap = count
                break
            }
        }
        return Array(olderContent.dropLast(overlap)) + collected
    }

    func declareAutomationAgent(alias: String, kind: KeroAgentKind) {
        agentObservation.alias = alias
        agentObservation.declaredKind = kind
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = false
        agentObservation.awaitingInitialPrompt = true
        agentObservation.commandGraceDeadline = Date().addingTimeInterval(5)
        updateAutomationAgentStatus(
            alias: alias,
            kind: kind,
            phase: .working,
            authority: .command,
            reason: "Kero launched \(kind.displayName)",
            processID: nil,
            unseen: false
        )
    }

    func markAutomationAgentPrompted() {
        guard let status = agentStatus else { return }
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = true
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
        updateAutomationAgentStatus(
            alias: status.alias,
            kind: status.kind,
            phase: .working,
            authority: .command,
            reason: "Prompt submitted",
            processID: surface.foregroundPid,
            unseen: false
        )
    }

    func reportAutomationAgent(
        phase: KeroAgentPhase,
        reason: String?
    ) -> Bool {
        let foreground = surface.foregroundPid
        let rememberedProcess = agentStatus?.processID
        let recognized = [rememberedProcess, foreground]
            .compactMap { $0 }
            .lazy
            .compactMap { processID -> (pid_t, KeroAgentKind)? in
                KeroAgentKind.recognize(processID: processID).map { (processID, $0) }
            }
            .first
        guard let (processID, detected) = recognized else { return false }
        let kind = agentStatus?.kind ?? agentObservation.declaredKind ?? detected
        guard kind == detected else { return false }
        let alias = agentStatus?.alias ?? agentObservation.alias ?? kind.rawValue
        agentObservation.alias = alias
        agentObservation.declaredKind = kind
        let focused = TerminalManager.automationIsSessionFocused(id)
        agentObservation.integrationPhase = phase
        agentObservation.integrationReason = reason
        agentObservation.commandGraceDeadline = nil
        if phase == .working || phase == .blocked {
            agentObservation.integrationTurnActive = true
        }

        // A newly launched interactive CLI commonly publishes its initial idle
        // event before Kero submits any task. Keep the deliberate `created`
        // state; readiness is process recognition, not a disposable lifecycle
        // turn that should appear as background completion.
        if agentObservation.awaitingInitialPrompt, phase == .idle {
            agentObservation.integrationPhase = nil
            agentObservation.integrationReason = nil
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .created,
                authority: .process,
                reason: "Agent process created; no task has been submitted",
                processID: processID,
                unseen: false
            )
            return true
        }

        let completedTurn = agentObservation.integrationTurnActive
            || agentStatus?.phase == .working
            || agentStatus?.phase == .blocked
        let presentedPhase: KeroAgentPhase
        switch phase {
        case .idle, .done:
            presentedPhase = completedTurn && !focused ? .done : .idle
            agentObservation.integrationTurnActive = false
        default:
            presentedPhase = phase
        }
        updateAutomationAgentStatus(
            alias: alias,
            kind: kind,
            phase: presentedPhase,
            authority: .integration,
            reason: reason ?? "Reported by native agent integration",
            processID: processID,
            unseen: presentedPhase == .done
        )
        return true
    }

    func markAutomationAgentSeen() {
        guard let status = agentStatus, status.phase == .done || status.unseen else { return }
        guard isAutomationAgentRunning(kind: status.kind) else {
            clearAutomationAgentStatus()
            return
        }
        agentObservation.integrationPhase = .idle
        agentObservation.integrationReason = "Completion viewed"
        agentObservation.integrationTurnActive = false
        updateAutomationAgentStatus(
            alias: status.alias,
            kind: status.kind,
            phase: .idle,
            authority: status.authority,
            reason: "Completion viewed",
            processID: status.processID,
            unseen: false
        )
    }

    fileprivate func refreshAutomationAgentState(isFocused: Bool) {
        if isFocused { markAutomationAgentSeen() }

        let foreground = surface.foregroundPid
        let shell = shellPid
        let processIsAgent = foreground != nil && foreground != shell
        let detectedKind = processIsAgent
            ? foreground.flatMap(KeroAgentKind.recognize(processID:))
            : nil
        let kind = detectedKind
        if detectedKind != nil {
            agentObservation.commandGraceDeadline = nil
        }

        if foreground != agentObservation.lastForegroundPID {
            agentObservation.lastForegroundPID = foreground
            if !processIsAgent {
                agentObservation.integrationPhase = nil
                agentObservation.integrationReason = nil
            }
        }

        guard let kind else {
            guard let previous = agentStatus else { return }
            if !processIsAgent {
                if previous.phase == .working,
                   previous.authority == .command,
                   let deadline = agentObservation.commandGraceDeadline,
                   Date() < deadline {
                    return
                }
                clearAutomationAgentStatus()
            }
            return
        }

        let alias = agentObservation.alias ?? agentStatus?.alias ?? kind.rawValue
        agentObservation.alias = alias
        let declaredKind = agentObservation.declaredKind
        agentObservation.declaredKind = kind

        // Directly launched CLIs have no `agent.start` declaration. Process
        // recognition records an idle presence, but terminal text never changes
        // lifecycle state; only commands and native integrations do that.
        if agentStatus == nil,
           agentObservation.integrationPhase == nil {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .idle,
                authority: .process,
                reason: "Directly launched \(kind.displayName) detected",
                processID: foreground,
                unseen: false
            )
        }

        if let phase = agentObservation.integrationPhase,
           phase != .working, phase != .blocked {
            // Presentation is decided when the native event arrives. Preserve
            // it until a new event or explicit focus acknowledges completion;
            // otherwise leaving an idle pane would turn it back into `done`.
            let currentPresentation = agentStatus.flatMap { status in
                status.authority == .integration
                    && (status.phase == .idle || status.phase == .done)
                    ? status : nil
            }
            let normalized = currentPresentation?.phase
                ?? ((phase == .idle || phase == .done) ? .idle : phase)
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: normalized,
                authority: .integration,
                reason: agentObservation.integrationReason
                    ?? "Reported by native agent integration",
                processID: foreground,
                unseen: currentPresentation?.unseen ?? (normalized == .done)
            )
            return
        }

        if agentObservation.awaitingInitialPrompt, declaredKind == kind {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .created,
                authority: .process,
                reason: "Agent process created; no task has been submitted",
                processID: foreground,
                unseen: false
            )
            return
        }

        if let phase = agentObservation.integrationPhase {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: phase,
                authority: .integration,
                reason: agentObservation.integrationReason
                    ?? "Reported by native agent integration",
                processID: foreground,
                unseen: false
            )
            return
        }

        if let current = agentStatus,
           current.phase == .working,
           current.authority == .command {
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: .working,
                authority: .command,
                reason: current.reason,
                processID: foreground,
                unseen: false
            )
            return
        }

        updateAutomationAgentStatus(
            alias: alias,
            kind: kind,
            phase: .idle,
            authority: .process,
            reason: "Directly launched \(kind.displayName) detected",
            processID: foreground,
            unseen: false
        )
    }

    private func clearAutomationAgentStatus() {
        agentStatus = nil
        agentObservation.alias = nil
        agentObservation.declaredKind = nil
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = false
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
    }

    private func updateAutomationAgentStatus(
        alias: String,
        kind: KeroAgentKind,
        phase: KeroAgentPhase,
        authority: KeroAgentStateAuthority,
        reason: String,
        processID: pid_t?,
        unseen: Bool
    ) {
        if let current = agentStatus,
           current.alias == alias,
           current.kind == kind,
           current.phase == phase,
           current.authority == authority,
           current.reason == reason,
           current.processID == processID,
           current.unseen == unseen {
            return
        }

        let previousPhase = agentStatus?.phase
        agentStatus = KeroAgentStatus(
            alias: alias,
            kind: kind,
            phase: phase,
            authority: authority,
            reason: reason,
            updatedAt: Date(),
            processID: processID,
            unseen: unseen
        )

        guard phase != previousPhase,
              phase == .blocked || phase == .done,
              !TerminalManager.automationIsSessionFocused(id)
        else { return }
        TerminalNotificationService.shared.post(
            message: phase == .blocked
                ? String(localized: "\(alias) needs attention")
                : String(localized: "\(alias) finished"),
            sessionID: id
        )
    }
}

extension PaneTab {
    var agentRollup: KeroAgentRollup? {
        Self.rollup(sessions.compactMap(\.agentStatus))
    }

    fileprivate static func rollup(_ statuses: [KeroAgentStatus]) -> KeroAgentRollup? {
        // Idle and unknown remain useful to automation clients, but neither is
        // actionable enough to occupy persistent pane, tab, or project chrome.
        let visibleStatuses = statuses.filter {
            $0.phase != .idle && $0.phase != .unknown
        }
        guard let phase = visibleStatuses.map(\.phase).max(by: {
            $0.rollupPriority < $1.rollupPriority
        }) else { return nil }
        return KeroAgentRollup(
            phase: phase,
            count: visibleStatuses.filter { $0.phase == phase }.count
        )
    }
}

extension TerminalSession {
    var agentRollup: KeroAgentRollup? {
        PaneTab.rollup(agentStatus.map { [$0] } ?? [])
    }
}

extension Project {
    var agentRollup: KeroAgentRollup? {
        PaneTab.rollup(sessions.compactMap(\.agentStatus))
    }
}
