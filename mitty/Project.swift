//
//  Project.swift
//  mitty
//

import Combine
import Foundation

/// A project groups terminal sessions and appears as one tab in the left
/// sidebar. It always starts with one session; closing the last session
/// empties the project, which removes it from the manager.
@MainActor
final class Project: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// User-assigned name; when nil the project title follows the
    /// selected session's terminal title.
    @Published var customName: String?
    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?

    /// Called after the last session is removed.
    var onEmptied: ((Project) -> Void)?

    private let fallbackName: String
    /// Sessions publish their own changes (title, directory); re-publish
    /// them so the project name and views observing the project stay current.
    private var sessionObservations: [UUID: AnyCancellable] = [:]

    init(fallbackName: String) {
        self.fallbackName = fallbackName
        newSession()
    }

    var name: String {
        if let customName, !customName.isEmpty {
            return customName
        }
        return selectedSession?.title ?? fallbackName
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    @discardableResult
    func newSession() -> TerminalSession {
        let session = TerminalSession()
        session.onExited = { [weak self] session in
            self?.remove(session)
        }
        sessionObservations[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessions.append(session)
        selectedSessionID = session.id
        return session
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

    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
    }

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedSessionID = sessions[index].id
    }

    func selectNext() {
        shiftSelection(by: 1)
    }

    func selectPrevious() {
        shiftSelection(by: -1)
    }

    private func shiftSelection(by offset: Int) {
        guard !sessions.isEmpty,
              let current = sessions.firstIndex(where: { $0.id == selectedSessionID })
        else { return }
        let next = (current + offset + sessions.count) % sessions.count
        selectedSessionID = sessions[next].id
    }

    private func remove(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        sessionObservations[session.id] = nil
        if selectedSessionID == session.id {
            let neighbor = min(index, sessions.count - 1)
            selectedSessionID = neighbor >= 0 ? sessions[neighbor].id : nil
        }
        if sessions.isEmpty {
            onEmptied?(self)
        }
    }
}
