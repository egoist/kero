//
//  Project.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// One tab in a project's header strip: a terminal session, an open file,
/// or a git diff.
enum ProjectTab: nonisolated Identifiable {
    case session(TerminalSession)
    case file(FileTab)
    case diff(DiffTab)

    nonisolated var id: UUID {
        switch self {
        case .session(let session): return session.id
        case .file(let file): return file.id
        case .diff(let diff): return diff.id
        }
    }
}

/// A project groups tabs (terminal sessions and open files) and appears as
/// one row in the left sidebar. It always starts with one session; closing
/// the last tab empties the project, which removes it from the manager.
@MainActor
final class Project: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// User-assigned name; when nil the project title follows the
    /// selected session's terminal title.
    @Published var customName: String?
    @Published var tabs: [ProjectTab] = []
    @Published var selectedTabID: UUID?

    /// Called after the last tab is removed.
    var onEmptied: ((Project) -> Void)?

    private let fallbackName: String
    /// Sessions publish their own changes (title, directory); re-publish
    /// them so the project name and views observing the project stay current.
    private var sessionObservations: [UUID: AnyCancellable] = [:]

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

    var sessions: [TerminalSession] {
        tabs.compactMap {
            if case .session(let session) = $0 { return session }
            return nil
        }
    }

    var selectedTab: ProjectTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var diffTabs: [DiffTab] {
        tabs.compactMap {
            if case .diff(let diff) = $0 { return diff }
            return nil
        }
    }

    /// The selected terminal session; while a file tab is selected this
    /// falls back to the project's first session so panels that need a
    /// working directory (file tree, git) keep tracking the project.
    var selectedSession: TerminalSession? {
        if case .session(let session)? = selectedTab {
            return session
        }
        return sessions.first
    }

    // MARK: - Sessions

    /// When no directory is given, the new session starts in the current
    /// session's working directory (home if the project has none yet).
    @discardableResult
    func newSession(directory: String? = nil) -> TerminalSession {
        let session = TerminalSession(
            initialDirectory: directory ?? selectedSession?.currentDirectoryPath
        )
        session.onExited = { [weak self] session in
            self?.remove(tabID: session.id)
        }
        sessionObservations[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        insertNextToSelected(.session(session))
        selectedTabID = session.id
        return session
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        remove(tabID: session.id)
    }

    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
    }

    // MARK: - Files

    /// Opens `path` as a file tab, reusing an existing tab for the same path.
    /// `editorState` seeds scroll/cursor state when restoring a saved tab.
    func openFile(_ path: String, editorState: EditorState? = nil) {
        if let existing = tabs.first(where: {
            if case .file(let file) = $0 { return file.path == path }
            return false
        }) {
            selectedTabID = existing.id
            return
        }
        let file = FileTab(path: path)
        if let editorState {
            file.editorState = editorState
        }
        insertNextToSelected(.file(file))
        selectedTabID = file.id
    }

    /// After a rename on disk, re-points any open file tab at its new path —
    /// the renamed file itself, or any file beneath a renamed directory.
    func updateFilePaths(from oldPath: String, to newPath: String) {
        for case .file(let file) in tabs {
            if file.path == oldPath {
                file.updatePath(newPath)
            } else if file.path.hasPrefix(oldPath + "/") {
                file.updatePath(newPath + String(file.path.dropFirst(oldPath.count)))
            }
        }
    }

    func close(_ file: FileTab) {
        guard file.isDirty else {
            remove(tabID: file.id)
            return
        }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        Task { @MainActor in
            _ = await confirmCloseUnsaved(file, in: window)
        }
    }

    /// Asks whether to save before discarding an edited file tab, matching the
    /// standard macOS Save / Don't Save / Cancel prompt. Presented as a sheet
    /// on `window` (app-modal only when there's no window) so it doesn't block
    /// the whole app. Returns `true` if the user backed out — Cancel, or a save
    /// that failed — so a batch close can stop before tearing down other tabs.
    ///
    /// This is `async` on purpose: awaiting the sheet means each prompt in a
    /// batch is presented only after the previous one has fully dismissed.
    /// Presenting the next sheet synchronously from the prior sheet's
    /// completion handler races AppKit's teardown and drops later sheets.
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
            // Keep the tab open if the write failed; the error bar shows why.
            guard file.saveError == nil else { return true }
            remove(tabID: file.id)
            return false
        case .alertSecondButtonReturn: // Don't Save
            remove(tabID: file.id)
            return false
        default: // Cancel
            return true
        }
    }

    // MARK: - Diffs

    /// Opens a git diff tab, reusing (and reloading) an existing tab for
    /// the same file and stage side.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        if let existing = diffTabs.first(where: {
            $0.repoRoot == repoRoot && $0.path == path && $0.staged == staged
        }) {
            existing.untracked = untracked
            existing.origPath = origPath
            existing.reload()
            selectedTabID = existing.id
            return
        }
        let diff = DiffTab(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
        insertNextToSelected(.diff(diff))
        selectedTabID = diff.id
    }

    func close(_ diff: DiffTab) {
        remove(tabID: diff.id)
    }

    // MARK: - Tab selection

    /// Closes a tab regardless of its kind — terminating sessions and
    /// honoring the unsaved-changes prompt for files.
    func close(_ tab: ProjectTab) {
        switch tab {
        case .session(let session): close(session)
        case .file(let file): close(file)
        case .diff(let diff): close(diff)
        }
    }

    func closeSelected() {
        guard let selectedTab else { return }
        close(selectedTab)
    }

    /// Closes every tab except `keep`.
    func closeOthers(_ keep: ProjectTab) {
        selectedTabID = keep.id
        closeBatch(tabs.filter { $0.id != keep.id })
    }

    /// Closes every tab positioned to the right of `tab` in the strip.
    func closeToRight(of tab: ProjectTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        closeBatch(Array(tabs[(index + 1)...]))
    }

    /// Closes every tab, which empties (and thus removes) the project.
    func closeAll() {
        closeBatch(tabs)
    }

    /// Closes several tabs at once. Any unsaved files are confirmed *first*,
    /// one prompt at a time; the remaining (clean) tabs are only torn down once
    /// every prompt has been answered — so cancelling out of a save prompt
    /// leaves the saved tabs open too, instead of losing them before the user
    /// decided.
    private func closeBatch(_ targets: [ProjectTab]) {
        let dirtyFiles = targets.compactMap { tab -> FileTab? in
            if case .file(let file) = tab, file.isDirty { return file }
            return nil
        }
        let cleanTabs = targets.filter { tab in
            if case .file(let file) = tab { return !file.isDirty }
            return true
        }

        guard !dirtyFiles.isEmpty else {
            cleanTabs.forEach { close($0) }
            return
        }

        let window = NSApp.keyWindow ?? NSApp.mainWindow
        Task { @MainActor in
            for file in dirtyFiles where file.isDirty {
                // Bail the moment the user backs out — the clean tabs, and any
                // files not yet prompted, stay open.
                if await confirmCloseUnsaved(file, in: window) { return }
            }
            cleanTabs.forEach { close($0) }
        }
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

    /// Inserts a newly created tab immediately after the current selection so
    /// new tabs open next to the current one instead of at the end of the
    /// strip. Appends when there's no selection — the first tab, or while
    /// restoring, where selection tracks the last tab added (so "after
    /// selected" lands at the end and the saved order is preserved).
    private func insertNextToSelected(_ tab: ProjectTab) {
        if let selectedTabID,
           let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    private func remove(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        sessionObservations[tabID] = nil
        if selectedTabID == tabID {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        if tabs.isEmpty {
            onEmptied?(self)
        }
    }
}
