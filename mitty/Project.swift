//
//  Project.swift
//  mitty
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
        tabs.append(.session(session))
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
        tabs.append(.file(file))
        selectedTabID = file.id
    }

    func close(_ file: FileTab) {
        guard file.isDirty else {
            remove(tabID: file.id)
            return
        }
        confirmCloseUnsaved(file)
    }

    /// Asks whether to save before discarding an edited file tab, matching the
    /// standard macOS Save / Don't Save / Cancel prompt. Presented as a sheet
    /// on the active window so it doesn't block the whole app.
    private func confirmCloseUnsaved(_ file: FileTab) {
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

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self, weak file] response in
            guard let self, let file else { return }
            switch response {
            case .alertFirstButtonReturn: // Save
                file.save()
                // Keep the tab open if the write failed; the error bar shows why.
                if file.saveError == nil {
                    self.remove(tabID: file.id)
                }
            case .alertSecondButtonReturn: // Don't Save
                self.remove(tabID: file.id)
            default: // Cancel
                break
            }
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
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
        tabs.append(.diff(diff))
        selectedTabID = diff.id
    }

    func close(_ diff: DiffTab) {
        remove(tabID: diff.id)
    }

    // MARK: - Tab selection

    func closeSelected() {
        switch selectedTab {
        case .session(let session): close(session)
        case .file(let file): close(file)
        case .diff(let diff): close(diff)
        case nil: break
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
