//
//  TerminalManager.swift
//  kero
//

import Combine
import Foundation
import SwiftUI

/// Panels available in the right sidebar.
enum RightPanel {
    case files
    case git
    case info
}

/// Owns the list of projects and the current selection. Each project holds
/// its own terminal sessions; the "selected session" is the selected
/// project's selected session.
@MainActor
final class TerminalManager: nonisolated ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedProjectID: UUID?
    @Published var isPanelVisible = false
    @Published var panelTab: RightPanel = .files
    @Published var isCommandPaletteVisible = false

    /// Projects publish their own changes (session list, session selection);
    /// re-publish them so views observing the manager stay current.
    private var projectObservations: [UUID: AnyCancellable] = [:]
    private var projectCounter = 0
    private var settingsObservation: AnyCancellable?
    private var gpuRenderingObservation: AnyCancellable?
    private var autosaveObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private var periodicSaveObservation: AnyCancellable?

    /// Live managers in window-creation order; the persisted snapshot is
    /// one entry per registered manager.
    private static var registry: [TerminalManager] = []
    /// Window snapshots loaded from disk that no window has claimed yet.
    /// Each new manager claims the next; extras beyond the saved count
    /// start fresh.
    private static var pendingRestores: [SessionSnapshot] = []
    private static var hasLoadedStore = false
    /// Set on app termination so window teardown can't re-save a partial
    /// snapshot over the final full one.
    private static var isQuitting = false
    private static var didReopenWindows = false

    init() {
        if !Self.hasLoadedStore {
            Self.hasLoadedStore = true
            Self.pendingRestores = SessionStore.load()
        }
        Self.registry.append(self)
        var restored = false
        if !Self.pendingRestores.isEmpty {
            restored = restore(from: Self.pendingRestores.removeFirst())
        }
        if !restored {
            newProject()
        }
        // Re-theme live sessions only when font settings change. Delivery is
        // scheduled onto the main queue because @Published emits in willSet.
        settingsObservation = Publishers.CombineLatest(
            AppSettings.shared.$fontFamily.removeDuplicates(),
            AppSettings.shared.$fontSize.removeDuplicates()
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAppearance()
            }
        // Renderer changes are separate so toggling Metal never resets the
        // font (which would clear the terminal's current selection).
        gpuRenderingObservation = AppSettings.shared.$gpuRenderingEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.setGPURenderingEnabled(enabled)
            }
        // Every project/tab/selection change re-publishes through the
        // manager, so a debounced sink snapshots after mutations settle.
        autosaveObservation = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { _ in
                TerminalManager.saveAll()
            }
        // The debounce can swallow changes made just before quitting;
        // capture a final snapshot while the shells are still alive.
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in
                TerminalManager.isQuitting = true
                TerminalManager.saveAll()
            }
        // Shell cwd changes don't always publish (not every shell emits
        // OSC 7), so also snapshot on a slow timer to survive force quits.
        periodicSaveObservation = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                TerminalManager.saveAll()
            }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: TerminalSession? {
        selectedProject?.selectedSession
    }

    // MARK: - Projects

    func newProject() {
        let project = makeProject()
        // Open the new project next to the current one rather than at the end.
        // Falls back to appending when nothing is selected yet.
        if let selectedProjectID,
           let index = projects.firstIndex(where: { $0.id == selectedProjectID }) {
            projects.insert(project, at: index + 1)
        } else {
            projects.append(project)
        }
        selectedProjectID = project.id
    }

    private func makeProject(createInitialSession: Bool = true) -> Project {
        projectCounter += 1
        let project = Project(
            fallbackName: "Project \(projectCounter)",
            createInitialSession: createInitialSession
        )
        project.onEmptied = { [weak self] project in
            self?.remove(project)
        }
        projectObservations[project.id] = project.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return project
    }

    func close(_ project: Project) {
        project.terminateAll()
        remove(project)
    }

    private func remove(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        projectObservations[project.id] = nil
        if selectedProjectID == project.id {
            let neighbor = min(index, projects.count - 1)
            selectedProjectID = neighbor >= 0 ? projects[neighbor].id : nil
        }
        // Nothing left to inspect once the last project is gone, so collapse
        // the right sidebar — its panels all track the selected session.
        if projects.isEmpty {
            isPanelVisible = false
        }
    }

    /// Moves a dragged project across `targetID`: after it when moving down,
    /// or before it when moving up. Selection continues to follow its project ID.
    func moveProject(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = projects.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = projects.firstIndex(where: { $0.id == targetID })
        else { return }

        var reorderedProjects = projects
        let draggedProject = reorderedProjects.remove(at: draggedIndex)
        reorderedProjects.insert(draggedProject, at: targetIndex)
        projects = reorderedProjects
    }

    func selectProject(index: Int) {
        guard projects.indices.contains(index) else { return }
        selectedProjectID = projects[index].id
    }

    func selectNextProject() {
        shiftProjectSelection(by: 1)
    }

    func selectPreviousProject() {
        shiftProjectSelection(by: -1)
    }

    private func shiftProjectSelection(by offset: Int) {
        guard !projects.isEmpty,
              let current = projects.firstIndex(where: { $0.id == selectedProjectID })
        else { return }
        let next = (current + offset + projects.count) % projects.count
        selectedProjectID = projects[next].id
    }

    // MARK: - Sessions

    /// New session in the current project; creates a project if none exist.
    func newSession() {
        guard let project = selectedProject else {
            newProject()
            return
        }
        project.newSession()
    }

    /// Clears the terminal in the focused pane. No-op while a file or diff pane
    /// is focused, so ⌘K never wipes an off-screen terminal.
    func clearActiveTerminal() {
        if case .session(let session)? = selectedProject?.focusedContent {
            session.clear()
        }
    }

    /// Whether ⌘K has a terminal on screen to act on right now.
    var canClearActiveTerminal: Bool {
        if case .session? = selectedProject?.focusedContent { return true }
        return false
    }

    /// Closes the focused pane (⌘W). When it's the last pane in its tab the
    /// tab closes too — matching the old single-content-tab behavior.
    func closeSelectedTab() {
        selectedProject?.closeFocusedPane()
    }

    // MARK: - Panes

    func splitRight() { selectedProject?.splitRight() }
    func splitLeft() { selectedProject?.splitLeft() }
    func splitDown() { selectedProject?.splitDown() }
    func splitUp() { selectedProject?.splitUp() }
    func split(toward edge: PaneDropEdge) { selectedProject?.split(toward: edge) }
    func focusPaneLeft() { selectedProject?.focusLeft() }
    func focusPaneRight() { selectedProject?.focusRight() }
    func focusPaneUp() { selectedProject?.focusUp() }
    func focusPaneDown() { selectedProject?.focusDown() }

    /// Whether the focused pane can be split right now (false for diffs / no
    /// project).
    var canSplit: Bool { selectedProject?.canSplit ?? false }

    func selectNextTab() {
        selectedProject?.selectNext()
    }

    func selectPreviousTab() {
        selectedProject?.selectPrevious()
    }

    // MARK: - Files

    /// Opens `path` as a file tab in the current project.
    func openFile(_ path: String) {
        selectedProject?.openFile(path)
    }

    /// Opens `path` as a pane beside the focused one in the current tab.
    func openFileToSide(_ path: String) {
        selectedProject?.openFileToSide(path)
    }

    /// Opens a git diff tab in the current project.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        selectedProject?.openDiff(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
    }

    /// Saves the focused pane if it holds a file.
    func saveSelectedFile() {
        if case .file(let file)? = selectedProject?.focusedContent {
            file.save()
        }
    }

    /// Propagates a file-tree rename to every open file tab across all
    /// projects, so tabs for the moved file (or files under a moved
    /// directory) keep pointing at the right place.
    func fileRenamed(from oldPath: String, to newPath: String) {
        for project in projects {
            project.updateFilePaths(from: oldPath, to: newPath)
        }
    }

    // MARK: - Panels & appearance

    func toggleSidebar() {
        isPanelVisible.toggle()
    }

    func toggleCommandPalette() {
        isCommandPaletteVisible.toggle()
    }

    /// Shows the sidebar on `panel`, or hides it if already showing that panel.
    func togglePanel(_ panel: RightPanel) {
        if isPanelVisible && panelTab == panel {
            isPanelVisible = false
        } else {
            panelTab = panel
            isPanelVisible = true
        }
    }

    /// Re-themes every session after a light/dark appearance change.
    func refreshAppearance() {
        for project in projects {
            for session in project.sessions {
                session.applyTheme()
            }
        }
    }

    /// Switches every live terminal between Metal and Core Graphics.
    private func setGPURenderingEnabled(_ enabled: Bool) {
        for project in projects {
            for session in project.sessions {
                session.setGPURenderingEnabled(enabled)
            }
        }
    }

    /// After the first window appears, reopen one window per unclaimed
    /// saved snapshot; each new window's manager claims the next one.
    /// Deferred a runloop tick so windows the system itself restores can
    /// claim theirs first.
    static func openRestoredWindows(_ open: @escaping () -> Void) {
        guard !didReopenWindows else { return }
        didReopenWindows = true
        DispatchQueue.main.async {
            for _ in 0..<pendingRestores.count {
                open()
            }
        }
    }

    /// Called when this manager's window closes: drop it from the
    /// persisted set — except for the last window, whose snapshot is kept
    /// saved and queued so reopening (or relaunching) restores it — and
    /// kill its shells.
    func windowClosed() {
        guard !Self.isQuitting else { return }
        let snapshot = makeWindowSnapshot()
        Self.registry.removeAll { $0 === self }
        if Self.registry.isEmpty {
            SessionStore.save([snapshot])
            Self.pendingRestores = [snapshot]
        } else {
            Self.saveAll()
        }
        for project in projects {
            project.terminateAll()
        }
    }

    // MARK: - Persistence

    private static func saveAll() {
        guard !registry.isEmpty else { return }
        SessionStore.save(registry.map { $0.makeWindowSnapshot() })
    }

    private func makeWindowSnapshot() -> SessionSnapshot {
        typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot
        return SessionSnapshot(
            projects: projects.compactMap { project in
                guard !project.tabs.isEmpty else { return nil }
                let tabs = project.tabs.map { tab -> ProjectSnapshot.TabSnapshot in
                    let columns = tab.columns.map { column in
                        ProjectSnapshot.ColumnSnapshot(
                            panes: column.panes.map { pane in
                                ProjectSnapshot.PaneSnapshot(
                                    content: Self.contentSnapshot(pane.content),
                                    weight: Double(pane.weight)
                                )
                            },
                            weight: Double(column.weight)
                        )
                    }
                    let (col, row) = tab.focusedLocation() ?? (0, 0)
                    return ProjectSnapshot.TabSnapshot(
                        columns: columns, focusedColumn: col, focusedRow: row
                    )
                }
                return ProjectSnapshot(
                    customName: project.customName,
                    tabs: tabs,
                    selectedTabIndex: project.tabs.firstIndex { $0.id == project.selectedTabID }
                )
            },
            selectedProjectIndex: projects.firstIndex { $0.id == selectedProjectID }
        )
    }

    private static func contentSnapshot(
        _ content: PaneContent
    ) -> SessionSnapshot.ProjectSnapshot.PaneContentSnapshot {
        switch content {
        case .session(let session):
            return .session(workingDirectory: session.currentDirectoryPath)
        case .file(let file):
            return .file(path: file.path, editorState: file.editorState)
        case .diff(let diff):
            return .diff(
                repoRoot: diff.repoRoot, path: diff.path, staged: diff.staged,
                untracked: diff.untracked, origPath: diff.origPath
            )
        }
    }

    /// Rebuilds projects and tabs from a saved window snapshot. Returns
    /// false when the snapshot holds nothing restorable.
    private func restore(from snapshot: SessionSnapshot) -> Bool {
        for saved in snapshot.projects where !saved.tabs.isEmpty {
            let project = makeProject(createInitialSession: false)
            project.customName = saved.customName
            for tab in saved.tabs {
                project.restoreTab(from: tab)
            }
            guard !project.tabs.isEmpty else {
                projectObservations[project.id] = nil
                continue
            }
            if let index = saved.selectedTabIndex, project.tabs.indices.contains(index) {
                project.selectedTabID = project.tabs[index].id
            }
            projects.append(project)
        }
        guard !projects.isEmpty else { return false }
        if let index = snapshot.selectedProjectIndex, projects.indices.contains(index) {
            selectedProjectID = projects[index].id
        } else {
            selectedProjectID = projects.first?.id
        }
        return true
    }
}
