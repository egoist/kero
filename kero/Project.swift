//
//  Project.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// A project groups tabs and appears as one row in the left sidebar. Each tab
/// is a niri-style layout of panes (terminal sessions and open files); see
/// `PaneTab`. It always starts with one session; closing the last pane empties
/// the project, which removes it from the manager.
@MainActor
final class Project: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// User-assigned name; when nil the project title follows the
    /// selected session's terminal title.
    @Published var customName: String?
    @Published var tabs: [PaneTab] = []
    @Published var selectedTabID: UUID?

    /// Called after the last tab is removed.
    var onEmptied: ((Project) -> Void)?

    private let fallbackName: String
    /// Sessions publish their own changes (title, directory); re-publish them
    /// so the project name and views observing the project stay current.
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    /// Tabs publish layout changes (splits, focus, resize); re-publish them so
    /// the strip re-renders and autosave fires.
    private var tabObservations: [UUID: AnyCancellable] = [:]

    /// Pass `createInitialSession: false` when restoring a saved project;
    /// the caller then rebuilds the tabs itself.
    init(fallbackName: String, createInitialSession: Bool = true) {
        self.fallbackName = fallbackName
        if createInitialSession {
            newSession()
        }
    }

    var name: String {
        if let customName, !customName.isEmpty {
            return customName
        }
        return selectedSession?.title ?? fallbackName
    }

    /// Every terminal session across every pane in every tab.
    var sessions: [TerminalSession] {
        tabs.flatMap(\.sessions)
    }

    var selectedTab: PaneTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Content of the focused pane in the selected tab.
    var focusedContent: PaneContent? {
        selectedTab?.focusedContent
    }

    /// Every diff shown anywhere, paired with the id of its containing tab so
    /// the content view can tell which one is currently on screen.
    var diffPlacements: [(diff: DiffTab, tabID: UUID)] {
        tabs.flatMap { tab in tab.diffs.map { (diff: $0, tabID: tab.id) } }
    }

    /// The focused terminal session; while a file (or diff) pane is focused
    /// this falls back to the project's first session so panels that need a
    /// working directory (file tree, git) keep tracking the project.
    var selectedSession: TerminalSession? {
        if case .session(let session)? = focusedContent {
            return session
        }
        return sessions.first
    }

    /// Whether the selected tab's focused pane can be split (false for diffs).
    var canSplit: Bool {
        selectedTab?.canSplit ?? false
    }

    // MARK: - Sessions

    /// When no directory is given, the new session starts in the current
    /// session's working directory (home if the project has none yet).
    @discardableResult
    func newSession(directory: String? = nil) -> TerminalSession {
        let session = makeSession(directory: directory)
        let tab = makeTab(content: .session(session))
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return session
    }

    /// Builds a session wired for exit + change observation, without placing
    /// it in a tab — shared by new tabs and splits.
    private func makeSession(directory: String? = nil) -> TerminalSession {
        let session = TerminalSession(
            initialDirectory: directory ?? selectedSession?.currentDirectoryPath
        )
        session.onExited = { [weak self] session in
            // Already dead — just drop its pane, no second terminate.
            self?.closeContent(.session(session), terminate: false)
        }
        sessionObservations[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return session
    }

    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
    }

    // MARK: - Splits

    func splitRight() { split(toward: .right) }
    func splitLeft() { split(toward: .left) }
    func splitDown() { split(toward: .bottom) }
    func splitUp() { split(toward: .top) }

    /// Splits the focused pane on `edge` with a fresh terminal. Left/right open
    /// a new column; top/bottom stack within the focused column. No-op while a
    /// diff is focused.
    func split(toward edge: PaneDropEdge) {
        guard let tab = selectedTab, tab.canSplit else { return }
        let session = makeSession()
        tab.split(Pane(content: .session(session)), toward: edge)
    }

    func focusLeft() { selectedTab?.focusLeft() }
    func focusRight() { selectedTab?.focusRight() }
    func focusUp() { selectedTab?.focusUp() }
    func focusDown() { selectedTab?.focusDown() }

    // MARK: - Files

    /// Opens `path` as a new file tab, reusing an existing tab/pane for the
    /// same path. `editorState` seeds scroll/cursor state when restoring.
    func openFile(_ path: String, editorState: EditorState? = nil) {
        if let (tab, paneID) = findFilePane(path: path) {
            selectedTabID = tab.id
            tab.focusedPaneID = paneID
            return
        }
        let file = FileTab(path: path)
        if let editorState {
            file.editorState = editorState
        }
        let tab = makeTab(content: .file(file))
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    /// Opens `path` as a new pane beside the focused one in the current tab
    /// ("Open to the Side"). Falls back to a fresh tab when the current tab
    /// can't take a split (e.g. it's a diff) or none is selected.
    func openFileToSide(_ path: String) {
        guard let tab = selectedTab, tab.canSplit else {
            openFile(path)
            return
        }
        if let existing = tab.allPanes.first(where: {
            if case .file(let file) = $0.content { return file.path == path }
            return false
        }) {
            tab.focusedPaneID = existing.id
            return
        }
        tab.split(Pane(content: .file(FileTab(path: path))), toward: .right)
    }

    private func findFilePane(path: String) -> (tab: PaneTab, paneID: UUID)? {
        for tab in tabs {
            if let pane = tab.allPanes.first(where: {
                if case .file(let file) = $0.content { return file.path == path }
                return false
            }) {
                return (tab, pane.id)
            }
        }
        return nil
    }

    /// After a rename on disk, re-points any open file pane at its new path —
    /// the renamed file itself, or any file beneath a renamed directory.
    func updateFilePaths(from oldPath: String, to newPath: String) {
        for tab in tabs {
            for case .file(let file) in tab.allContents {
                if file.path == oldPath {
                    file.updatePath(newPath)
                } else if file.path.hasPrefix(oldPath + "/") {
                    file.updatePath(newPath + String(file.path.dropFirst(oldPath.count)))
                }
            }
        }
    }

    // MARK: - Diffs

    /// Opens a git diff as a new tab, reusing (and reloading) an existing tab
    /// for the same file and stage side.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        if let (tab, pane) = findDiffPane(repoRoot: repoRoot, path: path, staged: staged),
           case .diff(let diff) = pane.content {
            diff.untracked = untracked
            diff.origPath = origPath
            diff.reload()
            selectedTabID = tab.id
            tab.focusedPaneID = pane.id
            return
        }
        let diff = DiffTab(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
        let tab = makeTab(content: .diff(diff))
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    private func findDiffPane(
        repoRoot: String, path: String, staged: Bool
    ) -> (tab: PaneTab, pane: Pane)? {
        for tab in tabs {
            if let pane = tab.allPanes.first(where: {
                if case .diff(let diff) = $0.content {
                    return diff.repoRoot == repoRoot && diff.path == path && diff.staged == staged
                }
                return false
            }) {
                return (tab, pane)
            }
        }
        return nil
    }

    // MARK: - Closing

    /// Closes one piece of content: terminates a session, prompts before
    /// discarding a dirty file, then removes its pane (dropping the tab when
    /// that was its last pane). `terminate` is false when a shell has already
    /// exited on its own.
    func closeContent(_ content: PaneContent, terminate: Bool = true) {
        switch content {
        case .session(let session):
            if terminate { session.terminate() }
            removePaneWithContent(content.id)
        case .file(let file):
            guard file.isDirty else {
                removePaneWithContent(content.id)
                return
            }
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            Task { @MainActor in
                _ = await confirmCloseUnsaved(file, in: window)
            }
        case .diff:
            removePaneWithContent(content.id)
        }
    }

    /// Closes the focused pane of the selected tab (⌘W).
    func closeFocusedPane() {
        guard let content = focusedContent else { return }
        closeContent(content)
    }

    func closeSelected() {
        closeFocusedPane()
    }

    /// Closes an entire tab — every pane it holds.
    func close(_ tab: PaneTab) {
        closeBatch(tab.allContents)
    }

    /// Closes every tab except `keep`.
    func closeOthers(_ keep: PaneTab) {
        selectedTabID = keep.id
        closeBatch(tabs.filter { $0.id != keep.id }.flatMap(\.allContents))
    }

    /// Closes every tab positioned to the right of `tab` in the strip.
    func closeToRight(of tab: PaneTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        closeBatch(Array(tabs[(index + 1)...]).flatMap(\.allContents))
    }

    /// Closes every tab, which empties (and thus removes) the project.
    func closeAll() {
        closeBatch(tabs.flatMap(\.allContents))
    }

    /// Asks whether to save before discarding an edited file, matching the
    /// standard macOS Save / Don't Save / Cancel prompt. Presented as a sheet
    /// on `window` (app-modal only when there's no window) so it doesn't block
    /// the whole app. Returns `true` if the user backed out — Cancel, or a save
    /// that failed — so a batch close can stop before tearing down other panes.
    ///
    /// This is `async` on purpose: awaiting the sheet means each prompt in a
    /// batch is presented only after the previous one has fully dismissed.
    @discardableResult
    private func confirmCloseUnsaved(_ file: FileTab, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to \(file.name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        switch response {
        case .alertFirstButtonReturn: // Save
            file.save()
            // Keep the pane open if the write failed; the error bar shows why.
            guard file.saveError == nil else { return true }
            removePaneWithContent(file.id)
            return false
        case .alertSecondButtonReturn: // Don't Save
            removePaneWithContent(file.id)
            return false
        default: // Cancel
            return true
        }
    }

    /// Closes several pieces of content at once. Any unsaved files are
    /// confirmed *first*, one prompt at a time; the remaining (clean) content
    /// is only torn down once every prompt has been answered — so cancelling
    /// out of a save prompt leaves the saved panes open too.
    private func closeBatch(_ targets: [PaneContent]) {
        let dirtyFiles = targets.compactMap { content -> FileTab? in
            if case .file(let file) = content, file.isDirty { return file }
            return nil
        }
        let cleanContents = targets.filter { content in
            if case .file(let file) = content { return !file.isDirty }
            return true
        }

        guard !dirtyFiles.isEmpty else {
            cleanContents.forEach { closeContent($0) }
            return
        }

        let window = NSApp.keyWindow ?? NSApp.mainWindow
        Task { @MainActor in
            for file in dirtyFiles where file.isDirty {
                // Bail the moment the user backs out — the clean panes, and any
                // files not yet prompted, stay open.
                if await confirmCloseUnsaved(file, in: window) { return }
            }
            cleanContents.forEach { closeContent($0) }
        }
    }

    // MARK: - Tab selection

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    func selectNext() {
        shiftSelection(by: 1)
    }

    func selectPrevious() {
        shiftSelection(by: -1)
    }

    private func shiftSelection(by offset: Int) {
        guard !tabs.isEmpty,
              let current = tabs.firstIndex(where: { $0.id == selectedTabID })
        else { return }
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    // MARK: - Layout mutation plumbing

    private func makeTab(content: PaneContent) -> PaneTab {
        register(PaneTab(content: content))
    }

    /// Wires a tab's change observation and returns it — used for fresh tabs
    /// and for tabs rebuilt during restore.
    @discardableResult
    func register(_ tab: PaneTab) -> PaneTab {
        tabObservations[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return tab
    }

    /// Rebuilds a saved tab's pane layout — recreating its sessions (wired for
    /// exit + observation), files and diffs — then registers and appends it.
    /// Skips panes whose content can't be rebuilt; a tab with none is dropped.
    func restoreTab(from snap: SessionSnapshot.ProjectSnapshot.TabSnapshot) {
        var columns: [PaneColumn] = []
        for columnSnap in snap.columns {
            var panes: [Pane] = []
            for paneSnap in columnSnap.panes {
                panes.append(Pane(
                    content: makeContent(from: paneSnap.content),
                    weight: CGFloat(paneSnap.weight)
                ))
            }
            guard !panes.isEmpty else { continue }
            columns.append(PaneColumn(panes: panes, weight: CGFloat(columnSnap.weight)))
        }
        guard !columns.isEmpty else { return }
        let col = min(max(0, snap.focusedColumn), columns.count - 1)
        let row = min(max(0, snap.focusedRow), columns[col].panes.count - 1)
        append(PaneTab(columns: columns, focusedPaneID: columns[col].panes[row].id))
    }

    private func makeContent(
        from snap: SessionSnapshot.ProjectSnapshot.PaneContentSnapshot
    ) -> PaneContent {
        switch snap {
        case .session(let workingDirectory):
            return .session(makeSession(directory: workingDirectory))
        case .file(let path, let editorState):
            let file = FileTab(path: path)
            if let editorState { file.editorState = editorState }
            return .file(file)
        case .diff(let repoRoot, let path, let staged, let untracked, let origPath):
            return .diff(DiffTab(
                repoRoot: repoRoot, path: path, staged: staged,
                untracked: untracked, origPath: origPath
            ))
        }
    }

    /// Inserts a newly created tab immediately after the current selection so
    /// new tabs open next to the current one instead of at the end of the
    /// strip. Appends when there's no selection — the first tab, or while
    /// restoring, where selection tracks the last tab added.
    private func insertNextToSelected(_ tab: PaneTab) {
        if let selectedTabID,
           let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    /// Appends a tab and selects it — used while restoring, which builds tabs
    /// in saved order.
    func append(_ tab: PaneTab) {
        register(tab)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Removes the pane holding `contentID` from whichever tab owns it, and
    /// drops the tab if that pane was its last.
    private func removePaneWithContent(_ contentID: UUID) {
        for tab in tabs {
            guard let paneID = tab.paneID(forContent: contentID) else { continue }
            // Keyed by session id; a no-op for files and diffs.
            sessionObservations[contentID] = nil
            if !tab.removePane(paneID) {
                remove(tabID: tab.id)
            }
            return
        }
    }

    private func remove(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        for session in tab.sessions {
            sessionObservations[session.id] = nil
        }
        tabObservations[tabID] = nil
        tabs.remove(at: index)
        if selectedTabID == tabID {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        if tabs.isEmpty {
            onEmptied?(self)
        }
    }
}
