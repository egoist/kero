//
//  Project.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// A project groups tabs and appears as one row in the left sidebar. Each tab
/// is a recursive split layout of terminal, file, browser, and diff panes; see
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
    @Published var selectedTabID: UUID? {
        didSet {
            guard selectedTabID != oldValue, let selectedTabID else { return }
            recentTabIDs.removeAll { $0 == selectedTabID }
            recentTabIDs.insert(selectedTabID, at: 0)
        }
    }

    /// Tab IDs newest-used first. Kept here rather than in the switcher
    /// because every way of reaching a tab — strip click, Ctrl-number,
    /// opening a file — counts as a use.
    private var recentTabIDs: [UUID] = []

    private let fallbackName: String
    /// Sessions publish their own changes (title, directory); re-publish them
    /// so the project name and views observing the project stay current.
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    /// Tabs publish layout changes (splits, focus, resize); re-publish them so
    /// the strip re-renders and autosave fires.
    private var tabObservations: [UUID: AnyCancellable] = [:]
    /// Browser navigation changes the tab's automatic title and persisted URL.
    /// Re-publish it through the project just like a terminal's live title and
    /// working directory.
    private var browserObservations: [UUID: AnyCancellable] = [:]

    /// Pass `createInitialSession: false` when restoring a saved project;
    /// the caller then rebuilds the tabs itself.
    init(fallbackName: String, createInitialSession: Bool = true) {
        self.fallbackName = fallbackName
        if createInitialSession {
            newSession()
        }
    }

    var name: String {
        if let customName = Self.normalizedCustomName(customName) {
            return customName
        }
        guard let title = selectedSession?.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallbackName
        }
        return title
    }

    /// Manual project names are user-authored labels, not terminal protocol
    /// payloads. Normalize only surrounding whitespace.
    static func normalizedCustomName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every terminal session across every pane in every tab.
    var sessions: [TerminalSession] {
        tabs.flatMap(\.sessions)
    }

    var selectedTab: PaneTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Tabs by recency of use, selected first. Tabs not yet selected this
    /// session trail in strip order, so the sequence covers every tab even
    /// before any switching has happened.
    var tabsByRecency: [PaneTab] {
        var seen = Set<UUID>()
        var ordered: [PaneTab] = []
        func add(_ tab: PaneTab) {
            guard seen.insert(tab.id).inserted else { return }
            ordered.append(tab)
        }
        if let selectedTab { add(selectedTab) }
        for id in recentTabIDs {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            add(tab)
        }
        tabs.forEach(add)
        return ordered
    }

    /// Drops recorded recency, leaving strip order behind the selected tab.
    /// Restoring a window selects each tab as it is rebuilt; without this the
    /// order would just mirror the rebuild.
    func resetRecency() {
        recentTabIDs = selectedTabID.map { [$0] } ?? []
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

    /// The focused terminal session; while a file, browser, or diff pane is
    /// focused it has no directory of its own, so panels that need a working
    /// directory (file tree, git, info) track a terminal that does: one sharing
    /// the tab (a split), else the session the content was opened from (the
    /// tab's `contextSession`), else the project's first session.
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

    /// Which rule produced the panel root, so labels can describe it
    /// truthfully instead of just saying "automatic".
    enum PanelRootSource: Equatable {
        /// The directory pinned on the project row.
        case pinned
        /// The repository the shell itself sits in.
        case shell
        /// The repository the terminal's foreground job sits in — a coding
        /// agent that moved to another checkout of the same project. Whether
        /// that checkout is a linked worktree is resolved here, once per
        /// refresh, so views can label it without touching the disk.
        case foreground(isWorktree: Bool)
    }

    /// Root for the file tree and git panels: the pinned directory when the
    /// user set one (and it still exists on disk), else the repository the
    /// terminal's foreground job moved to (an agent's worktree), else the
    /// closest git repository containing `cwd`, else `cwd` itself — the
    /// follow-the-terminal behavior used before projects had a directory.
    /// Everything but the pin is re-derived on every call, so the panels
    /// track the session in and out of repositories without sticking.
    func panelRoot(
        followingSessionAt cwd: String, foregroundAt foregroundCwd: String? = nil
    ) -> (root: String, source: PanelRootSource) {
        if let pinned = customDirectory, FileManager.default.fileExists(atPath: pinned) {
            return (pinned, .pinned)
        }
        let shellRoot = Self.closestGitRepository(containing: cwd) ?? cwd
        // Only a *different repository* re-roots the panels. A foreground job
        // running in a subdirectory of the shell's own checkout resolves to
        // the same root and is ignored, which keeps the file tree from
        // collapsing its expanded rows every time a command runs.
        if let foregroundCwd,
           let foregroundRoot = Self.closestGitRepository(containing: foregroundCwd),
           foregroundRoot != shellRoot {
            return (foregroundRoot, .foreground(isWorktree: Self.isLinkedWorktree(foregroundRoot)))
        }
        return (shellRoot, .shell)
    }

    /// Whether `root` is a linked worktree rather than a normal checkout: its
    /// `.git` is a file pointing into the main repository's `worktrees`
    /// directory (a submodule's points into `modules` instead).
    private static func isLinkedWorktree(_ root: String) -> Bool {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let contents = try? String(contentsOfFile: gitPath, encoding: .utf8)
        else { return false }
        return contents.contains("/worktrees/")
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
    func newSession(
        directory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil
    ) -> TerminalSession {
        let session = makeSession(
            directory: directory,
            commandArguments: commandArguments,
            environmentPath: environmentPath
        )
        let tab = makeTab(content: .session(session))
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return session
    }

    /// Builds a session wired for exit + change observation, without placing
    /// it in a tab — shared by new tabs and splits. `restoredHistory` seeds the
    /// scrollback when reopening a saved session.
    private func makeSession(
        directory: String? = nil,
        restoredHistory: String? = nil,
        commandArguments: [String]? = nil,
        environmentPath: String? = nil
    ) -> TerminalSession {
        let session = TerminalSession(
            initialDirectory: directory
                ?? selectedSession?.currentDirectoryPath
                ?? customDirectory,
            restoredHistory: restoredHistory,
            commandArguments: commandArguments,
            environmentPath: environmentPath
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

    /// Splits the focused pane's rectangle on `edge` with a fresh terminal.
    /// No-op while a diff is focused.
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

    // MARK: - Browser

    /// Opens a native browser as a new tab beside the current selection.
    @discardableResult
    func newBrowserTab(
        initialURL: String? = nil,
        initialFocus: BrowserTab.InitialFocus = .addressBar
    ) -> BrowserTab {
        let context = selectedSession
        let browser = makeBrowser(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        let tab = makeTab(content: .browser(browser))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return browser
    }

    /// Opens a native browser to the right of the focused pane in the current
    /// tab. Unlike a normal terminal split, the new pane owns a WKWebView.
    @discardableResult
    func newBrowserPane(
        toward edge: PaneDropEdge = .right,
        initialURL: String? = nil,
        initialFocus: BrowserTab.InitialFocus = .addressBar
    ) -> BrowserTab? {
        guard let tab = selectedTab, tab.canSplit else { return nil }
        let browser = makeBrowser(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        tab.split(Pane(content: .browser(browser)), toward: edge)
        return browser
    }

    private func makeBrowser(
        initialURL: String?,
        initialFocus: BrowserTab.InitialFocus
    ) -> BrowserTab {
        let browser = BrowserTab(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        browserObservations[browser.id] = browser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return browser
    }

    // MARK: - File paths

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
        case .browser:
            removePaneWithContent(content.id)
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
        alert.messageText = String(
            localized: "Do you want to save the changes you made to \(file.name)?",
            comment: "Unsaved file confirmation. The placeholder is a file name."
        )
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
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
        let layout = restoreLayout(from: snap.layout, histories: histories)
        let panes = layout.allPanes
        guard !panes.isEmpty else { return }
        let focusedIndex = min(max(0, snap.focusedPaneIndex), panes.count - 1)
        let tab = PaneTab(layout: layout, focusedPaneID: panes[focusedIndex].id)
        tab.customName = snap.customName
        append(tab)
    }

    private func restoreLayout(
        from snap: SessionSnapshot.ProjectSnapshot.LayoutSnapshot,
        histories: [String: String]
    ) -> PaneNode {
        switch snap {
        case .pane(let pane):
            let restoredHistory = pane.historyKey.flatMap { histories[$0] }
            return .pane(Pane(content: makeContent(
                from: pane.content, restoredHistory: restoredHistory
            )))
        case .split(let axis, let fraction, let first, let second):
            return .split(PaneSplit(
                axis: axis,
                fraction: CGFloat(fraction),
                first: restoreLayout(from: first, histories: histories),
                second: restoreLayout(from: second, histories: histories)
            ))
        }
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
        case .browser(let url):
            return .browser(makeBrowser(initialURL: url, initialFocus: .none))
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
            // Keyed by content id; no-ops for the other content kinds.
            sessionObservations[contentID] = nil
            browserObservations[contentID] = nil
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
        for browser in tab.browsers {
            browserObservations[browser.id] = nil
        }
        tabObservations[tabID] = nil
        recentTabIDs.removeAll { $0 == tabID }
        tabs.remove(at: index)
        if selectedTabID == tabID {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        // Emptying the project does not close it — the project row stays in the
        // sidebar until the user explicitly closes it.
    }
}
