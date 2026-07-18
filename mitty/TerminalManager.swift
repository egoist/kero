//
//  TerminalManager.swift
//  mitty
//

import Combine
import Foundation
import SwiftUI

/// Panels available in the right sidebar.
enum RightPanel {
    case files
    case git
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
    private var autosaveObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    private var periodicSaveObservation: AnyCancellable?

    init() {
        if !restoreSnapshot() {
            newProject()
        }
        // Re-theme live sessions when font settings change. objectWillChange
        // fires before the value lands, so hop through the main queue.
        settingsObservation = AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAppearance()
            }
        // Every project/tab/selection change re-publishes through the
        // manager, so a debounced sink snapshots after mutations settle.
        autosaveObservation = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.saveSnapshot()
            }
        // The debounce can swallow changes made just before quitting;
        // capture a final snapshot while the shells are still alive.
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.saveSnapshot()
            }
        // Shell cwd changes don't always publish (not every shell emits
        // OSC 7), so also snapshot on a slow timer to survive force quits.
        periodicSaveObservation = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.saveSnapshot()
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
        projects.append(project)
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

    func closeSelectedTab() {
        selectedProject?.closeSelected()
    }

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

    /// Opens a git diff tab in the current project.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        selectedProject?.openDiff(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
    }

    /// Saves the selected tab if it is a file tab.
    func saveSelectedFile() {
        if case .file(let file)? = selectedProject?.selectedTab {
            file.save()
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

    // MARK: - Persistence

    private func saveSnapshot() {
        let snapshot = SessionSnapshot(
            projects: projects.compactMap { project in
                guard !project.tabs.isEmpty else { return nil }
                let tabs = project.tabs.map { tab -> SessionSnapshot.ProjectSnapshot.Tab in
                    switch tab {
                    case .session(let session):
                        return .session(workingDirectory: session.currentDirectoryPath)
                    case .file(let file):
                        return .file(path: file.path)
                    case .diff(let diff):
                        return .diff(
                            repoRoot: diff.repoRoot, path: diff.path, staged: diff.staged,
                            untracked: diff.untracked, origPath: diff.origPath
                        )
                    }
                }
                return SessionSnapshot.ProjectSnapshot(
                    customName: project.customName,
                    tabs: tabs,
                    selectedTabIndex: project.tabs.firstIndex { $0.id == project.selectedTabID }
                )
            },
            selectedProjectIndex: projects.firstIndex { $0.id == selectedProjectID }
        )
        SessionStore.save(snapshot)
    }

    /// Rebuilds projects and tabs from the last saved snapshot. Returns
    /// false when there is nothing to restore.
    private func restoreSnapshot() -> Bool {
        guard let snapshot = SessionStore.load() else { return false }
        for saved in snapshot.projects where !saved.tabs.isEmpty {
            let project = makeProject(createInitialSession: false)
            project.customName = saved.customName
            for tab in saved.tabs {
                switch tab {
                case .session(let workingDirectory):
                    project.newSession(directory: workingDirectory)
                case .file(let path):
                    project.openFile(path)
                case .diff(let repoRoot, let path, let staged, let untracked, let origPath):
                    project.openDiff(
                        repoRoot: repoRoot, path: path, staged: staged,
                        untracked: untracked, origPath: origPath
                    )
                }
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
