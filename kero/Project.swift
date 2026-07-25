//
//  Project.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// A project groups tabs and appears as one row in the left sidebar. Each tab
/// is a niri-style layout of panes (terminal sessions and open files); see
/// `PaneTab`. It always starts with one session; closing the last tab leaves
/// the project open but empty — only the explicit "Close Project" action (see
/// `TerminalManager.close(_:)`) removes it from the manager.
@MainActor
final class Project: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// User-assigned name; when nil the project title follows the
    /// selected session's terminal title.
    @Published var customName: String?
    /// User-pinned project directory ("Set Project Directory…" on the
    /// project row). When set, the file tree and git panels always anchor
    /// here. Nil means automatic: the closest git repository containing the
    /// selected session's working directory, re-derived as the session
    /// moves (see `panelRoot(followingSessionAt:)`).
    @Published var customDirectory: String?
    @Published var tabs: [PaneTab] = []
    @Published var selectedTabID: UUID?
    /// A tab whose strip item should open its inline rename field, requested
    /// from outside the strip (the command palette, the Info panel). The strip
    /// consumes and clears it. The pane-level counterpart lives on `PaneTab`.
    @Published var pendingRenameTabID: UUID?

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

    /// The focused terminal session; while a file (or diff) pane is focused it
    /// has no directory of its own, so panels that need a working directory
    /// (file tree, git, info) track a terminal that does: one sharing the
    /// file's tab (a split), else the session the file was opened from (the
    /// tab's `contextSession`), else the project's first session. The last two
    /// fallbacks are why opening a file from one tab kept showing another tab's
    /// directory when it landed on `sessions.first`.
    var selectedSession: TerminalSession? {
        if case .session(let session)? = focusedContent {
            return session
        }
        return selectedTab?.sessions.first
            ?? selectedTab?.contextSession
            ?? sessions.first
    }

    /// Whether the selected tab's focused pane can be split (false for diffs).
    var canSplit: Bool {
        selectedTab?.canSplit ?? false
    }

    // MARK: - Project directory

    /// Root for the file tree and git panels: the pinned directory when the
    /// user set one (and it still exists on disk), else the closest git
    /// repository containing `cwd`, else `cwd` itself — the
    /// follow-the-terminal behavior used before projects had a directory.
    /// The automatic repository root is re-derived on every call, so it
    /// tracks the session in and out of repositories without sticking.
    /// `isAutomatic` reports which branch produced the root, so labels can
    /// say "(AUTO)" truthfully even when a vanished pin forced the fallback.
    func panelRoot(followingSessionAt cwd: String) -> (root: String, isAutomatic: Bool) {
        if let pinned = customDirectory, FileManager.default.fileExists(atPath: pinned) {
            return (pinned, false)
        }
        return (Self.closestGitRepository(containing: cwd) ?? cwd, true)
    }

    /// The directory of the nearest enclosing git repository: walks up from
    /// `path` looking for a `.git` entry — a directory in normal checkouts,
    /// a file in worktrees and submodules.
    private static func closestGitRepository(containing path: String) -> String? {
        var dir = (path as NSString).standardizingPath
        guard dir.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
    }

    // MARK: - Sessions

    /// When no directory is given, the new session starts in the current
    /// session's working directory, then the pinned project directory
    /// (home when neither is known).
    @discardableResult
    func newSession(directory: String? = nil) -> TerminalSession {
        let session = makeSession(directory: directory)
        let tab = makeTab(content: .session(session))
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return session
    }

    /// Builds a session wired for exit + change observation, without placing
    /// it in a tab — shared by new tabs and splits. `restoredHistory` seeds the
    /// scrollback when reopening a saved session.
    private func makeSession(
        directory: String? = nil, restoredHistory: String? = nil
    ) -> TerminalSession {
        let session = TerminalSession(
            initialDirectory: directory
                ?? selectedSession?.currentDirectoryPath
                ?? customDirectory,
            restoredHistory: restoredHistory
        )
        observe(session)
        return session
    }

    /// Wires a session to this project: its exit closure and its change
    /// re-publishing both point at whichever project currently holds it. Called
    /// again on adoption, so a session that moves between projects reports its
    /// exit to its new owner rather than the one that started it.
    private func observe(_ session: TerminalSession) {
        session.onExited = { [weak self] session in
            // Already dead — just drop its pane, no second terminate.
            self?.closeContent(.session(session), terminate: false)
        }
        sessionObservations[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
    func focusNextPane() { selectedTab?.focusNext() }
    func focusPreviousPane() { selectedTab?.focusPrevious() }

    func togglePaneZoom() { selectedTab?.toggleZoom() }
    func equalizePanes() { selectedTab?.equalize() }
    func resizePaneUp() { selectedTab?.resizeUp() }
    func resizePaneDown() { selectedTab?.resizeDown() }
    func resizePaneLeft() { selectedTab?.resizeLeft() }
    func resizePaneRight() { selectedTab?.resizeRight() }

    /// Whether the selected tab is a split layout — gates zoom, resize and
    /// equalize.
    var hasSplitPanes: Bool { selectedTab?.hasMultiplePanes ?? false }

    /// Whether the selected tab is showing a zoomed pane.
    var isPaneZoomed: Bool { selectedTab?.isZoomed ?? false }

    // MARK: - Naming the focused pane

    /// Every terminal in the project paired with the name its pane shows, for
    /// listings that identify a shell by where it lives rather than by its
    /// title alone. A pane in a split carries its own name; a pane that is its
    /// whole tab is named by the tab, which is what the strip renames.
    var namedSessions: [(session: TerminalSession, name: String?)] {
        tabs.flatMap { tab in
            tab.allPanes.compactMap { pane in
                guard case .session(let session) = pane.content else { return nil }
                return (session, tab.hasMultiplePanes ? pane.customName : tab.customName)
            }
        }
    }

    /// The name shown for the focused pane — and the place a rename of it
    /// lands: the pane's own name inside a split, the tab's when the tab holds
    /// a single pane. Keeping those the same field is what makes renaming from
    /// the palette or the Info panel agree with renaming by hand, where a lone
    /// pane is renamed through the tab strip and a split pane through its
    /// header.
    var focusedPaneName: String? {
        guard let tab = selectedTab else { return nil }
        return tab.hasMultiplePanes ? tab.focusedPane?.customName : tab.customName
    }

    /// The title the focused pane falls back to when it has no name.
    var focusedPaneAutomaticTitle: String? {
        selectedTab?.focusedContent?.title
    }

    /// Renames the focused pane, or clears the name back to automatic when
    /// `name` is nil or blank.
    func renameFocusedPane(to name: String?) {
        guard let tab = selectedTab else { return }
        if tab.hasMultiplePanes, let paneID = tab.focusedPane?.id {
            tab.renamePane(paneID, to: name)
        } else {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// Opens the inline rename field on the focused pane — its header strip in
    /// a split, its tab in the strip when it is the tab's only pane.
    func beginRenamingFocusedPane() {
        guard let tab = selectedTab else { return }
        if tab.hasMultiplePanes {
            tab.pendingRenamePaneID = tab.focusedPaneID
        } else {
            pendingRenameTabID = tab.id
        }
    }

    // MARK: - Moving panes between tabs

    /// Pulls a pane out of `tab` into a tab of its own — the drag-a-pane-onto-
    /// the-strip gesture — inserted at `index` in the strip (appended after the
    /// source tab when nil) and selected. The pane keeps its content, so a
    /// running shell is carried across rather than restarted. A no-op when the
    /// pane is the tab's only one: it already *is* the whole tab.
    @discardableResult
    func extractPane(_ paneID: UUID, from tab: PaneTab, at index: Int? = nil) -> PaneTab? {
        guard let pane = tab.extractPane(paneID) else { return nil }
        let newTab = register(PaneTab(pane: pane))
        let fallback = tabs.firstIndex { $0.id == tab.id }.map { $0 + 1 } ?? tabs.count
        tabs.insert(newTab, at: min(max(0, index ?? fallback), tabs.count))
        selectedTabID = newTab.id
        return newTab
    }

    /// Hands a tab off to another project: drops it from the strip and clears
    /// the bookkeeping it holds here, terminating nothing. The tab object — and
    /// every shell inside it — lives on for `adopt(_:)` to take up.
    func release(tabID: UUID) -> PaneTab? {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        remove(tabID: tabID)
        return tab
    }

    /// Takes in a tab released by another project. Re-wiring is the whole job:
    /// each session's exit closure and change observation still point at the
    /// project that made it, so without this a moved shell would report its
    /// exit to the project it left.
    func adopt(_ tab: PaneTab) {
        for session in tab.sessions {
            observe(session)
        }
        register(tab)
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    /// Whether a tab may be dropped into another tab's layout. Diffs keep their
    /// own single-pane tab (their web view fills the tab), so neither side may
    /// hold one.
    func canMerge(_ tab: PaneTab, into target: PaneTab) -> Bool {
        tab.id != target.id && tab.diffs.isEmpty && target.diffs.isEmpty
    }

    /// Moves every pane of the dragged tab into the tab holding `targetPaneID`,
    /// splitting that pane on `edge`, then drops the emptied tab from the strip
    /// — the drag-a-tab-onto-a-pane gesture. Nothing is torn down: the panes,
    /// and the shells inside them, move across intact.
    func mergeTab(_ draggedID: UUID, into targetPaneID: UUID, edge: PaneDropEdge) {
        guard let dragged = tabs.first(where: { $0.id == draggedID }),
              let target = tabs.first(where: { tab in
                  tab.allPanes.contains { $0.id == targetPaneID }
              }),
              canMerge(dragged, into: target)
        else { return }

        var columns = dragged.columns
        // A named single-pane tab hands its name down to the pane, so the label
        // the user gave it survives as the pane's header title.
        if let name = dragged.customName, columns.count == 1, columns[0].panes.count == 1,
           columns[0].panes[0].customName == nil {
            columns[0].panes[0].customName = name
        }
        // Detach before inserting: the panes are about to have a new home, so
        // their sessions' observations must stay wired.
        remove(tabID: dragged.id, keepingSessionObservations: true)
        target.insert(columns, edge, of: targetPaneID)
        selectedTabID = target.id
    }

    // MARK: - Files

    /// Opens `path` as a new file tab, reusing an existing tab/pane for the
    /// same path. `editorState` seeds scroll/cursor state when restoring.
    func openFile(_ path: String, editorState: EditorState? = nil) {
        if let (tab, paneID) = findFilePane(path: path) {
            selectedTabID = tab.id
            tab.focusedPaneID = paneID
            return
        }
        // Capture the current directory context *before* selection moves to the
        // new tab, so its panels track the tab the file was opened from.
        let context = selectedSession
        let file = FileTab(path: path)
        if let editorState {
            file.editorState = editorState
        }
        let tab = makeTab(content: .file(file))
        tab.contextSession = context
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
        let context = selectedSession
        let diff = DiffTab(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
        let tab = makeTab(content: .diff(diff))
        tab.contextSession = context
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

    /// Closes every tab, leaving the project open but empty.
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

    /// Moves a dragged tab across `targetID`: after it when moving right, or
    /// before it when moving left. Selection continues to follow its tab ID.
    func moveTab(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetID })
        else { return }

        var reorderedTabs = tabs
        let draggedTab = reorderedTabs.remove(at: draggedIndex)
        reorderedTabs.insert(draggedTab, at: targetIndex)
        tabs = reorderedTabs
    }

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
    func restoreTab(
        from snap: SessionSnapshot.ProjectSnapshot.TabSnapshot,
        histories: [String: String] = [:]
    ) {
        var columns: [PaneColumn] = []
        for columnSnap in snap.columns {
            var panes: [Pane] = []
            for paneSnap in columnSnap.panes {
                let restoredHistory = paneSnap.historyKey.flatMap { histories[$0] }
                panes.append(Pane(
                    content: makeContent(from: paneSnap.content, restoredHistory: restoredHistory),
                    weight: CGFloat(paneSnap.weight),
                    customName: paneSnap.customName
                ))
            }
            guard !panes.isEmpty else { continue }
            columns.append(PaneColumn(panes: panes, weight: CGFloat(columnSnap.weight)))
        }
        guard !columns.isEmpty else { return }
        let col = min(max(0, snap.focusedColumn), columns.count - 1)
        let row = min(max(0, snap.focusedRow), columns[col].panes.count - 1)
        let tab = PaneTab(columns: columns, focusedPaneID: columns[col].panes[row].id)
        tab.customName = snap.customName
        append(tab)
    }

    private func makeContent(
        from snap: SessionSnapshot.ProjectSnapshot.PaneContentSnapshot,
        restoredHistory: String? = nil
    ) -> PaneContent {
        switch snap {
        case .session(let workingDirectory):
            return .session(makeSession(directory: workingDirectory, restoredHistory: restoredHistory))
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

    /// Drops a tab from the strip. `keepingSessionObservations` is set when the
    /// tab's panes are being re-homed rather than closed (a merge), so their
    /// sessions keep re-publishing through the project.
    private func remove(tabID: UUID, keepingSessionObservations: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        if !keepingSessionObservations {
            for session in tab.sessions {
                sessionObservations[session.id] = nil
            }
        }
        tabObservations[tabID] = nil
        tabs.remove(at: index)
        if selectedTabID == tabID {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        // Emptying the project does not close it — the project row stays in the
        // sidebar until the user explicitly closes it.
    }
}
