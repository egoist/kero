import Foundation

struct SSHIdentity: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    let publicKey: String
    let fingerprint: String
    let createdAt: Date
    let requiresUserPresence: Bool
}
