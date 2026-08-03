import Foundation

struct KnownHostRecord: Codable, Hashable, Identifiable {
    var id: String { endpoint }

    let endpoint: String
    let openSSHKey: String
    let fingerprint: String
    let trustedAt: Date
}

enum KnownHostEvaluation {
    case trusted
    case unknown(proposed: KnownHostRecord)
    case changed(existing: KnownHostRecord, proposed: KnownHostRecord)
}

@MainActor
final class KnownHostStore: ObservableObject {
    @Published private(set) var records: [KnownHostRecord]

    private let storageURL: URL
    private var recordsByEndpoint: [String: KnownHostRecord]

    init(
        storageURL: URL = JSONFileStore.applicationSupportURL(filename: "known-hosts.json")
    ) {
        self.storageURL = storageURL
        let loaded = JSONFileStore.load(
            [KnownHostRecord].self,
            from: storageURL,
            default: []
        )
        self.records = loaded.sorted { $0.endpoint < $1.endpoint }
        self.recordsByEndpoint = Dictionary(
            uniqueKeysWithValues: loaded.map { ($0.endpoint, $0) }
        )
    }

    func evaluate(host: SSHHost, openSSHKey: String) -> KnownHostEvaluation {
        let proposed = KnownHostRecord(
            endpoint: host.normalizedEndpoint,
            openSSHKey: openSSHKey,
            fingerprint: SSHKeyFingerprint.make(fromOpenSSHKey: openSSHKey),
            trustedAt: Date()
        )

        let existing = recordsByEndpoint[host.normalizedEndpoint]

        guard let existing else {
            return .unknown(proposed: proposed)
        }
        if existing.openSSHKey == openSSHKey {
            return .trusted
        }
        return .changed(existing: existing, proposed: proposed)
    }

    func trust(_ record: KnownHostRecord) throws {
        var updatedByEndpoint = recordsByEndpoint
        updatedByEndpoint[record.endpoint] = record
        let updated = updatedByEndpoint.values.sorted { $0.endpoint < $1.endpoint }
        try JSONFileStore.save(updated, to: storageURL)
        recordsByEndpoint = updatedByEndpoint
        records = updated
    }

    func delete(_ record: KnownHostRecord) throws {
        var updatedByEndpoint = recordsByEndpoint
        updatedByEndpoint.removeValue(forKey: record.endpoint)
        let updated = updatedByEndpoint.values.sorted { $0.endpoint < $1.endpoint }
        try JSONFileStore.save(updated, to: storageURL)
        recordsByEndpoint = updatedByEndpoint
        records = updated
    }

    func deleteAll() throws {
        try JSONFileStore.save([KnownHostRecord](), to: storageURL)
        recordsByEndpoint = [:]
        records = []
    }
}
