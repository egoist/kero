import Crypto
import Foundation
import NIOSSH

@MainActor
final class IdentityStore: ObservableObject {
    @Published private(set) var identities: [SSHIdentity]

    private let storageURL: URL
    private let keychain: KeychainStore

    init(
        storageURL: URL = JSONFileStore.applicationSupportURL(filename: "identities.json"),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.storageURL = storageURL
        self.keychain = keychain
        self.identities = JSONFileStore.load([SSHIdentity].self, from: storageURL, default: [])
    }

    var sortedIdentities: [SSHIdentity] {
        identities.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    func generate(name: String, requiresUserPresence: Bool) throws -> SSHIdentity {
        let cryptoKey = Curve25519.Signing.PrivateKey()
        let privateKey = NIOSSHPrivateKey(ed25519Key: cryptoKey)
        let publicKey = String(openSSHPublicKey: privateKey.publicKey)
        let identity = SSHIdentity(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            publicKey: publicKey,
            fingerprint: SSHKeyFingerprint.make(fromOpenSSHKey: publicKey),
            createdAt: Date(),
            requiresUserPresence: requiresUserPresence
        )

        try keychain.save(
            cryptoKey.rawRepresentation,
            account: privateKeyAccount(for: identity.id),
            requiresUserPresence: requiresUserPresence
        )
        identities.append(identity)

        do {
            try persist()
        } catch {
            try? keychain.delete(account: privateKeyAccount(for: identity.id))
            identities.removeAll { $0.id == identity.id }
            throw error
        }
        return identity
    }

    func privateKey(for identityID: UUID, hostName: String) throws -> NIOSSHPrivateKey {
        guard let identity = identities.first(where: { $0.id == identityID }) else {
            throw IdentityStoreError.identityNotFound
        }
        let rawKey = try keychain.read(
            account: privateKeyAccount(for: identity.id),
            reason: "Use \(identity.name) to connect to \(hostName)"
        )
        let cryptoKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return NIOSSHPrivateKey(ed25519Key: cryptoKey)
    }

    func privateKeyForConnection(
        for identityID: UUID,
        hostName: String
    ) async throws -> NIOSSHPrivateKey {
        guard let identity = identities.first(where: { $0.id == identityID }) else {
            throw IdentityStoreError.identityNotFound
        }
        let rawKey = try await keychain.readAsync(
            account: privateKeyAccount(for: identity.id),
            reason: "Use \(identity.name) to connect to \(hostName)"
        )
        let cryptoKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        return NIOSSHPrivateKey(ed25519Key: cryptoKey)
    }

    func rename(_ identity: SSHIdentity, to name: String) throws {
        guard let index = identities.firstIndex(where: { $0.id == identity.id }) else {
            throw IdentityStoreError.identityNotFound
        }
        var updated = identities
        updated[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist(updated)
        identities = updated
    }

    func delete(_ identity: SSHIdentity) throws {
        let previous = identities
        let updated = identities.filter { $0.id != identity.id }
        try persist(updated)
        do {
            try keychain.deleteIfPresent(account: privateKeyAccount(for: identity.id))
            identities = updated
        } catch {
            try? persist(previous)
            throw error
        }
    }

    func deleteAll() throws {
        let previous = identities
        try persist([])
        do {
            for identity in previous {
                try keychain.deleteIfPresent(
                    account: privateKeyAccount(for: identity.id)
                )
            }
            identities = []
        } catch {
            try? persist(previous)
            throw error
        }
    }

    private func privateKeyAccount(for identityID: UUID) -> String {
        "identity.\(identityID.uuidString.lowercased()).ed25519"
    }

    private func persist(_ value: [SSHIdentity]? = nil) throws {
        try JSONFileStore.save(value ?? identities, to: storageURL)
    }
}

enum IdentityStoreError: LocalizedError {
    case identityNotFound

    var errorDescription: String? {
        "The selected SSH key is no longer available."
    }
}

enum SSHKeyFingerprint {
    static func make(fromOpenSSHKey openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2,
              let data = Data(base64Encoded: String(parts[1])) else {
            return "Unavailable"
        }
        let digest = SHA256.hash(data: data)
        return "SHA256:" + Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }
}
