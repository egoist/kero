import Foundation

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SSHHost]

    private let storageURL: URL
    private let keychain: KeychainStore

    init(
        storageURL: URL = JSONFileStore.applicationSupportURL(filename: "hosts.json"),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.storageURL = storageURL
        self.keychain = keychain
        self.hosts = JSONFileStore.load([SSHHost].self, from: storageURL, default: [])
    }

    var sortedHosts: [SSHHost] {
        hosts.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite
            }
            switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
            case let (.some(left), .some(right)) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    func host(id: UUID) -> SSHHost? {
        hosts.first { $0.id == id }
    }

    func upsert(_ host: SSHHost, password: String?) throws {
        let previous = self.host(id: host.id)
        var updatedHosts = hosts
        if let index = updatedHosts.firstIndex(where: { $0.id == host.id }) {
            updatedHosts[index] = host
        } else {
            updatedHosts.append(host)
        }

        if host.authentication == .identity {
            try persist(updatedHosts)
            do {
                try keychain.deleteIfPresent(
                    account: passwordAccount(for: host.id)
                )
                hosts = updatedHosts
            } catch {
                try? persist(hosts)
                throw error
            }
            return
        }

        let suppliedPassword = password.flatMap {
            $0.isEmpty ? nil : $0
        }
        let needsNewPassword = previous == nil
            || previous?.authentication != .password
        guard !needsNewPassword || suppliedPassword != nil else {
            throw HostStoreError.passwordRequired
        }

        let protectionChanged = previous?.authentication == .password
            && previous?.passwordRequiresUserPresence
                != host.passwordRequiresUserPresence
        let updatesCredential = suppliedPassword != nil || protectionChanged
        var previousPassword: String?

        if updatesCredential, let previous,
           previous.authentication == .password {
            previousPassword = try self.password(for: previous)
        }

        if updatesCredential {
            let replacement = suppliedPassword ?? previousPassword
            guard let replacement else {
                throw HostStoreError.passwordRequired
            }
            do {
                try keychain.save(
                    Data(replacement.utf8),
                    account: passwordAccount(for: host.id),
                    requiresUserPresence: host.passwordRequiresUserPresence
                )
            } catch {
                restorePassword(
                    previousPassword,
                    for: previous,
                    hostID: host.id
                )
                throw error
            }
        }

        do {
            try persist(updatedHosts)
            hosts = updatedHosts
        } catch {
            if updatesCredential {
                restorePassword(
                    previousPassword,
                    for: previous,
                    hostID: host.id
                )
            }
            throw error
        }
    }

    func password(for host: SSHHost) throws -> String {
        let data = try keychain.read(
            account: passwordAccount(for: host.id),
            reason: "Connect to \(host.displayName)"
        )
        return try password(from: data)
    }

    func passwordForConnection(for host: SSHHost) async throws -> String {
        let data = try await keychain.readAsync(
            account: passwordAccount(for: host.id),
            reason: "Connect to \(host.displayName)"
        )
        return try password(from: data)
    }

    private func password(from data: Data) throws -> String {
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return password
    }

    func toggleFavorite(_ host: SSHHost) throws {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
            return
        }
        var updated = hosts
        updated[index].isFavorite.toggle()
        try persist(updated)
        hosts = updated
    }

    func markConnected(_ hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
            return
        }
        var updated = hosts
        updated[index].lastConnectedAt = Date()
        guard (try? persist(updated)) != nil else {
            return
        }
        hosts = updated
    }

    func delete(_ host: SSHHost) throws {
        let previous = hosts
        let updated = hosts.filter { $0.id != host.id }
        try persist(updated)
        do {
            try keychain.deleteIfPresent(account: passwordAccount(for: host.id))
            hosts = updated
        } catch {
            try? persist(previous)
            throw error
        }
    }

    func deleteAll() throws {
        let previous = hosts
        try persist([])
        do {
            for host in previous {
                try keychain.deleteIfPresent(account: passwordAccount(for: host.id))
            }
            hosts = []
        } catch {
            try? persist(previous)
            throw error
        }
    }

    private func passwordAccount(for hostID: UUID) -> String {
        "host.\(hostID.uuidString.lowercased()).password"
    }

    private func restorePassword(
        _ password: String?,
        for previousHost: SSHHost?,
        hostID: UUID
    ) {
        guard let previousHost,
              previousHost.authentication == .password,
              let password else {
            try? keychain.deleteIfPresent(
                account: passwordAccount(for: hostID)
            )
            return
        }
        try? keychain.save(
            Data(password.utf8),
            account: passwordAccount(for: previousHost.id),
            requiresUserPresence: previousHost.passwordRequiresUserPresence
        )
    }

    private func persist(_ value: [SSHHost]? = nil) throws {
        try JSONFileStore.save(value ?? hosts, to: storageURL)
    }
}

enum HostStoreError: LocalizedError {
    case passwordRequired

    var errorDescription: String? {
        "Enter a password for this host."
    }
}
