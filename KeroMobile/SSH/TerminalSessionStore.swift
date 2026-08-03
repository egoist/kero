import Foundation

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSessionModel] = []

    private let hostStore: HostStore
    private let identityStore: IdentityStore
    private let knownHostStore: KnownHostStore

    init(
        hostStore: HostStore,
        identityStore: IdentityStore,
        knownHostStore: KnownHostStore
    ) {
        self.hostStore = hostStore
        self.identityStore = identityStore
        self.knownHostStore = knownHostStore
    }

    func openSession(for host: SSHHost) -> TerminalSessionModel {
        if let existing = session(forHostID: host.id) {
            return existing
        }

        let session = TerminalSessionModel(
            host: host,
            hostStore: hostStore,
            identityStore: identityStore,
            knownHostStore: knownHostStore
        )
        sessions.insert(session, at: 0)
        return session
    }

    func session(forHostID hostID: UUID) -> TerminalSessionModel? {
        sessions.first { $0.host.id == hostID }
    }

    func close(_ session: TerminalSessionModel) {
        session.disconnect()
        sessions.removeAll { $0 === session }
    }

    func closeSession(forHostID hostID: UUID) {
        guard let session = session(forHostID: hostID) else {
            return
        }
        close(session)
    }

    func closeAll() {
        sessions.forEach { $0.disconnect() }
        sessions.removeAll()
    }

    func suspendForBackground() {
        sessions.forEach { session in
            if !session.isUnlockingCredential {
                session.suspendForBackground()
            }
        }
    }

    func resumeVisibleSessions() {
        sessions.forEach { $0.resumeAfterBackgroundIfVisible() }
    }
}
