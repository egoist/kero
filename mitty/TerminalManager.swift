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

/// Owns the list of terminal sessions and the current selection.
@MainActor
final class TerminalManager: nonisolated ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published var isPanelVisible = false
    @Published var panelTab: RightPanel = .files

    func toggleSidebar() {
        isPanelVisible.toggle()
    }

    /// Re-themes every session after a light/dark appearance change.
    func refreshAppearance() {
        for session in sessions {
            session.applyTheme()
        }
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

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    init() {
        newSession()
    }

    func newSession() {
        let session = TerminalSession()
        session.onExited = { [weak self] session in
            self?.remove(session)
        }
        sessions.append(session)
        selectedID = session.id
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        remove(session)
    }

    func closeSelected() {
        if let session = selectedSession {
            close(session)
        }
    }

    private func remove(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        if selectedID == session.id {
            let neighbor = min(index, sessions.count - 1)
            selectedID = neighbor >= 0 ? sessions[neighbor].id : nil
        }
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedID = sessions[index].id
    }

    func selectNext() {
        shiftSelection(by: 1)
    }

    func selectPrevious() {
        shiftSelection(by: -1)
    }

    private func shiftSelection(by offset: Int) {
        guard !sessions.isEmpty,
              let current = sessions.firstIndex(where: { $0.id == selectedID })
        else { return }
        let next = (current + offset + sessions.count) % sessions.count
        selectedID = sessions[next].id
    }
}
