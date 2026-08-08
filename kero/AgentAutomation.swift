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
    /// Kero classified the live terminal UI after repeated observations.
    case screen
    /// Kero recognized the foreground executable.
    case process
    /// Kero just launched or prompted the agent and is awaiting observation.
    case command
}

private enum KeroAgentScreenDisposition {
    case working
    case blocked
    case idle
    case hold
}

private struct KeroAgentScreenSnapshot {
    let fingerprint: Int
    let disposition: KeroAgentScreenDisposition
}

/// A compact, deliberately conservative subset of Herdr's terminal-manifest
/// model. The process identity selects the rules; terminal text never decides
/// which agent is running. Agents without a specific working rule still use
/// the debounced, post-activity idle fallback instead of model self-reporting.
private nonisolated enum KeroAgentScreenClassifier {
    static func snapshot(
        kind: KeroAgentKind,
        title: String,
        visibleText: String
    ) -> KeroAgentScreenSnapshot {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(visibleText)

        let lowerTitle = title.lowercased()
        let recentLines = visibleText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(12)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let recent = recentLines.joined(separator: "\n").lowercased()
        let evidence = lowerTitle + "\n" + recent

        let disposition: KeroAgentScreenDisposition
        if isTranscriptOrPicker(kind: kind, recent: recent) {
            disposition = .hold
        } else if isBlocked(evidence) {
            disposition = .blocked
        } else if isWorking(
            kind: kind,
            lowerTitle: lowerTitle,
            recent: recent,
            recentLines: recentLines
        ) {
            disposition = .working
        } else {
            // This is Herdr's known-agent idle fallback: once task activity
            // has actually been observed, no working/blocker rule means the
            // interactive agent has settled. The caller debounces publication.
            disposition = .idle
        }

        return KeroAgentScreenSnapshot(
            fingerprint: hasher.finalize(), disposition: disposition
        )
    }

    private static func isTranscriptOrPicker(
        kind: KeroAgentKind,
        recent: String
    ) -> Bool {
        if recent.contains("showing detailed transcript") { return true }
        if recent.contains("select model")
            && recent.contains("esc to cancel") { return true }
        guard kind == .codex else { return false }
        let scrolling = recent.contains("↑/↓ to scroll")
            || recent.contains("pgup/pgdn")
            || recent.contains("home/end to jump")
        return scrolling && recent.contains("q to quit")
    }

    private static func isBlocked(_ recent: String) -> Bool {
        let strongSignals = [
            "action required",
            "permission required",
            "plugin confirmation needed",
            "waiting for approval",
            "waiting for user confirmation",
            "waiting for permission",
            "allow command?",
            "allow execution",
            "apply this change",
            "run this command?",
            "write to this file?",
            "reject & propose changes",
            "skip (esc or n)",
            "keep (n)",
            "invoke tool",
            "allow editing file:",
            "allow creating file:",
            "confirm tool call",
            "deny with feedback",
            "enter to submit answer",
            "enter to submit all",
            "do you want to allow this connection?",
            "tab to amend",
            "ctrl+e to explain",
            "review your answers",
            "skip interview and plan immediately",
            "(y) (enter)",
            "[y/n]",
        ]
        if strongSignals.contains(where: recent.contains) { return true }
        if recent.contains("do you want to proceed")
            && (recent.contains("yes") || recent.contains("esc to cancel")) {
            return true
        }
        if recent.contains("would you like to")
            && (recent.contains("yes") || recent.contains("❯")) {
            return true
        }
        return recent.contains("enter to confirm")
            && recent.contains("esc to cancel")
    }

    private static func isWorking(
        kind: KeroAgentKind,
        lowerTitle: String,
        recent: String,
        recentLines: [String]
    ) -> Bool {
        switch kind {
        case .pi:
            return recent.contains("working...")
        case .codex:
            return hasBraillePrefix(lowerTitle)
                || (recent.contains("working (")
                    && recent.contains("esc to interrupt"))
        case .claude:
            return hasBraillePrefix(lowerTitle)
                || (recent.contains("/btw") && recent.contains("esc to close"))
        case .gemini:
            return recent.contains("esc to cancel")
        case .opencode:
            return recent.contains("esc to interrupt")
                || recent.contains("ctrl+c to interrupt")
                || recent.contains("■■■■")
                || recent.contains("⬝⬝⬝⬝")
        case .cursor:
            return recent.contains("ctrl+c to stop")
                || recentLines.contains(where: hasCursorBackgroundTaskLine)
                || recentLines.contains(where: hasSpinnerVerbPrefix)
        case .amp:
            return hasBraillePrefix(lowerTitle)
                || recent.contains("esc to cancel")
                || recentLines.contains(where: hasAmpStatusLine)
        case .aider:
            return false
        }
    }

    private static func hasBraillePrefix(_ value: String) -> Bool {
        guard let scalar = value.unicodeScalars.first else { return false }
        return (0x2800...0x28ff).contains(Int(scalar.value))
    }

    private static func hasSpinnerVerbPrefix(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return false }
        let spinner = first.value == 0x2b21 || first.value == 0x2b22
            || (0x2800...0x28ff).contains(Int(first.value))
        guard spinner else { return false }
        let words = trimmed.lowercased().split(whereSeparator: { !$0.isLetter })
        guard let verb = words.dropFirst().first else { return false }
        return verb.hasSuffix("ing")
    }

    private static func hasCursorBackgroundTaskLine(_ line: String) -> Bool {
        let words = line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let count = words.first, Int(count) != nil else { return false }
        return words.dropFirst().first == "background"
            && words.dropFirst(2).first?.hasPrefix("task") == true
    }

    private static func hasAmpStatusLine(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.hasPrefix("╰"), lower.contains("─") else { return false }
        return [" thinking ", " streaming ", " running tools ", " waiting "]
            .contains(where: lower.contains)
    }
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
    var screenPromptedAt: Date?
    var lastScreenFingerprint: Int?
    var screenChangeCount = 0
    var screenObservedWorking = false
    var screenIdleConfirmations = 0
    var isCollectingAlternateScreenHistory = false
    /// A Kero-launched process is `created` until its first guarded prompt.
    /// This lifecycle fact does not require guessing how the CLI renders UI.
    var awaitingInitialPrompt = false
    /// Shell input is asynchronous. Keep a freshly declared launch working
    /// briefly so the monitor cannot mistake the still-foreground shell for
    /// an agent that already exited before it has consumed the command.
    var commandGraceDeadline: Date?

    func beginScreenObservation(fingerprint: Int, at date: Date = Date()) {
        screenPromptedAt = date
        lastScreenFingerprint = fingerprint
        screenChangeCount = 0
        screenObservedWorking = false
        screenIdleConfirmations = 0
    }

    func resetScreenObservation() {
        screenPromptedAt = nil
        lastScreenFingerprint = nil
        screenChangeCount = 0
        screenObservedWorking = false
        screenIdleConfirmations = 0
    }
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
        agentObservation.resetScreenObservation()
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
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
        agentObservation.beginScreenObservation(
            fingerprint: automationAgentScreenSnapshot(kind: status.kind).fingerprint
        )
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
            agentObservation.beginScreenObservation(
                fingerprint: automationAgentScreenSnapshot(kind: kind).fingerprint
            )
        } else {
            agentObservation.resetScreenObservation()
        }

        // A newly launched interactive CLI commonly publishes its initial idle
        // event before Kero submits any task. Keep the deliberate `created`
        // state; readiness is process recognition, not a disposable lifecycle
        // turn that should appear as background completion.
        if agentObservation.awaitingInitialPrompt, phase == .idle {
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

        let presentedPhase = automationPresentedPhase(
            integrationPhase: phase,
            isFocused: focused
        )
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
        if status.authority == .screen {
            agentObservation.integrationPhase = nil
            agentObservation.integrationReason = nil
        } else {
            agentObservation.integrationPhase = .idle
            agentObservation.integrationReason = "Completion viewed"
        }
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

    private func automationAgentScreenSnapshot(
        kind: KeroAgentKind
    ) -> KeroAgentScreenSnapshot {
        KeroAgentScreenClassifier.snapshot(
            kind: kind,
            title: title,
            visibleText: automationVisibleText(maxLines: 80, maxColumns: 500)
        )
    }

    /// Integrations publish the semantic idle state. `done` is Kero's unseen
    /// presentation of that same state, not something a model must announce.
    private func automationPresentedPhase(
        integrationPhase: KeroAgentPhase,
        isFocused: Bool
    ) -> KeroAgentPhase {
        switch integrationPhase {
        case .idle, .done:
            return isFocused ? .idle : .done
        default:
            return integrationPhase
        }
    }

    /// Herdr treats a known agent with no matching working/blocker rule as
    /// idle, then publishes that idle state as done when it is unseen. Kero
    /// adds a post-prompt activity gate because its terminal exports are
    /// sampled less frequently than Herdr's in-memory bottom-buffer reader.
    private func automationScreenFallback(
        kind: KeroAgentKind,
        isFocused: Bool,
        now: Date = Date()
    ) -> (phase: KeroAgentPhase, reason: String)? {
        guard terminalIsAtLiveBottom,
              let promptedAt = agentObservation.screenPromptedAt else { return nil }
        let snapshot = automationAgentScreenSnapshot(kind: kind)
        if snapshot.fingerprint != agentObservation.lastScreenFingerprint {
            agentObservation.lastScreenFingerprint = snapshot.fingerprint
            agentObservation.screenChangeCount += 1
            agentObservation.screenIdleConfirmations = 0
        }

        switch snapshot.disposition {
        case .hold:
            agentObservation.screenIdleConfirmations = 0
            return nil
        case .working:
            agentObservation.screenObservedWorking = true
            agentObservation.screenIdleConfirmations = 0
            return (.working, "Working terminal UI detected")
        case .blocked:
            agentObservation.screenObservedWorking = true
            agentObservation.screenIdleConfirmations = 0
            return (.blocked, "Terminal UI is waiting for input")
        case .idle:
            let elapsed = now.timeIntervalSince(promptedAt)
            let activityObserved = agentObservation.screenObservedWorking
                || agentObservation.screenChangeCount >= 2
                || (agentObservation.screenChangeCount >= 1 && elapsed >= 3)
            guard activityObserved else { return nil }
            agentObservation.screenIdleConfirmations += 1
            guard agentObservation.screenIdleConfirmations >= 3 else { return nil }
            return (
                isFocused ? .idle : .done,
                "Terminal UI settled after task activity"
            )
        }
    }

    fileprivate func refreshAutomationAgentState(isFocused: Bool) {
        if isFocused { markAutomationAgentSeen() }

        // Collecting transcript pages deliberately moves a full-screen agent's
        // own viewport. Those screen changes are reads, not lifecycle evidence.
        if agentObservation.isCollectingAlternateScreenHistory { return }

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

        if let phase = agentObservation.integrationPhase,
           phase != .working, phase != .blocked {
            let normalized = automationPresentedPhase(
                integrationPhase: phase,
                isFocused: isFocused
            )
            updateAutomationAgentStatus(
                alias: alias,
                kind: kind,
                phase: normalized,
                authority: .integration,
                reason: agentObservation.integrationReason
                    ?? "Reported by native agent integration",
                processID: foreground,
                unseen: normalized == .done
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

        let screenCanSettle = agentObservation.screenPromptedAt != nil
            && agentObservation.integrationPhase == nil
            && (agentStatus?.authority == .command
                || agentStatus?.authority == .screen)
        if screenCanSettle {
            if let inferred = automationScreenFallback(kind: kind, isFocused: isFocused) {
                updateAutomationAgentStatus(
                    alias: alias,
                    kind: kind,
                    phase: inferred.phase,
                    authority: .screen,
                    reason: inferred.reason,
                    processID: foreground,
                    unseen: inferred.phase == .done
                )
                return
            }
            // Transcript viewers and an idle candidate still inside its
            // confirmation window must not erase the last screen result.
            if agentStatus?.authority == .screen { return }
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
            phase: .unknown,
            authority: .process,
            reason: "No prompted task is being observed",
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
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
        agentObservation.resetScreenObservation()
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
        // Unknown is useful to automation clients diagnosing a recognized but
        // unobserved process, but it gives people no actionable chrome state.
        let visibleStatuses = statuses.filter { $0.phase != .unknown }
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
