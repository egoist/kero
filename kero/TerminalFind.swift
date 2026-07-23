//
//  TerminalFind.swift
//  kero
//

import AppKit
import Combine
import Foundation
import GhosttyTerminal

/// One Find menu command, routed from the menu bar to the focused pane's
/// find bar.
enum TerminalFindAction {
    case show
    case hide
    case next
    case previous
    case useSelection
}

/// Find-in-terminal state for one session.
///
/// Ghostty owns the search itself — it scans the screen and scrollback on its
/// own thread, highlights every match in its renderer, and moves the selection
/// as you navigate — so this holds only what the find bar draws and forwards
/// the user's intent as surface search actions. Match counts arrive back
/// asynchronously through `TerminalSurfaceSearchDelegate`.
@MainActor
final class TerminalFind: nonisolated ObservableObject {
    @Published private(set) var isPresented = false

    /// The needle. Every edit restarts Ghostty's search, so the bar searches
    /// as you type.
    @Published var query = "" {
        didSet {
            guard query != oldValue, !isApplyingReportedNeedle else { return }
            runSearch()
        }
    }

    /// Matches found so far, or nil while a count for the current needle has
    /// not been reported yet.
    @Published private(set) var total: Int?
    /// Zero-based index of the highlighted match, nil when none is.
    @Published private(set) var selected: Int?

    /// Bumped whenever the bar should take (or retake) keyboard focus, so ⌘F
    /// on an already-open bar re-selects the term the way the system find bar
    /// does. A counter rather than a flag: repeated requests must each land.
    @Published private(set) var focusRequest = 0

    /// The session owning this also owns the terminal view, so an unowned
    /// reference is safe and keeps the session's object graph acyclic.
    private unowned let terminal: KeroTerminalView

    /// Set while a needle Ghostty resolved for us (⌘E's selection) is being
    /// written into `query`, so echoing it back as a fresh search — which
    /// would restart the one already running — is suppressed.
    private var isApplyingReportedNeedle = false

    /// Bumped per search so a deferred reveal belonging to an older needle can
    /// tell it has been superseded. Ghostty reports each restart as a burst of
    /// counts, several per keystroke.
    private var searchGeneration = 0
    /// Whether the current needle has already jumped to a match.
    private var hasRevealedMatch = false

    init(terminal: KeroTerminalView) {
        self.terminal = terminal
    }

    // MARK: - Find menu

    func perform(_ action: TerminalFindAction) {
        switch action {
        case .show: present()
        case .hide: dismiss()
        case .next: navigate(forward: true)
        case .previous: navigate(forward: false)
        case .useSelection: searchSelection()
        }
    }

    // MARK: - Commands

    /// Shows the bar and focuses its field. The needle survives a close, so
    /// reopening offers the previous term again, pre-selected.
    func present() {
        isPresented = true
        focusRequest += 1
        runSearch()
    }

    /// Closes the bar, clears Ghostty's highlights, and hands typing back to
    /// the terminal.
    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        clearCounts()
        terminal.endSearch()
    }

    /// Returns first responder to the terminal. Called once the find bar has
    /// actually left the view tree, because claiming it any earlier loses the
    /// race with SwiftUI tearing down the find field: AppKit resigns that
    /// field editor afterwards and the window is left without a first
    /// responder, so the terminal silently stops receiving keystrokes.
    func restoreTerminalFocus() {
        DispatchQueue.main.async { [terminal] in
            guard NSApp.isActive,
                  let window = terminal.window,
                  window.isKeyWindow,
                  window.firstResponder !== terminal
            else { return }
            window.makeFirstResponder(terminal)
        }
    }

    func navigate(forward: Bool) {
        guard !query.isEmpty else { return }
        // ⌘G with the bar closed resumes the last search rather than doing
        // nothing, matching how Find Next behaves elsewhere on macOS.
        guard isPresented else {
            present()
            return
        }
        terminal.navigateSearch(forward: forward)
    }

    /// ⌘E. Ghostty resolves the needle from the grid selection and reports it
    /// back through ``started(needle:)``, so the selection never has to be
    /// read out and re-escaped here.
    func searchSelection() {
        guard terminal.hasSelection else { return }
        terminal.searchSelection()
    }

    // MARK: - Reports from libghostty

    func started(needle: String) {
        // Only claim keyboard focus when this actually opens the bar. Ghostty
        // may report a start for a search already under way, and re-selecting
        // the field mid-edit would eat what the user is typing.
        if !isPresented {
            isPresented = true
            focusRequest += 1
        }
        guard !needle.isEmpty, needle != query else { return }
        isApplyingReportedNeedle = true
        query = needle
        isApplyingReportedNeedle = false
    }

    /// Ghostty ended the search on its own. Mirror it without sending
    /// `end_search` straight back at it.
    func ended() {
        isPresented = false
        clearCounts()
    }

    func update(total: Int?) {
        self.total = total
        revealFirstMatchIfNeeded()
    }

    func update(selected: Int?) {
        self.selected = selected
    }

    /// Ghostty tallies matches but selects none until asked, so the first
    /// non-empty result for a needle jumps to one — typing in the find bar is
    /// meant to reveal the hit, not merely count it. Deferred so it never
    /// re-enters libghostty from inside its own action callback, and dropped
    /// when the needle has moved on by the time it runs.
    private func revealFirstMatchIfNeeded() {
        guard !hasRevealedMatch, let total, total > 0 else { return }
        hasRevealedMatch = true
        let generation = searchGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, isPresented, searchGeneration == generation else { return }
            terminal.navigateSearch(forward: true)
        }
    }

    // MARK: - Search

    /// Restarts Ghostty's search for the current needle. Counts are dropped
    /// first so the bar never shows a tally belonging to the previous term.
    private func runSearch() {
        guard isPresented else { return }
        searchGeneration += 1
        hasRevealedMatch = false
        clearCounts()
        terminal.search(query)
    }

    private func clearCounts() {
        total = nil
        selected = nil
    }
}
