import Foundation

enum SSHAuthenticationKind: String, Codable, CaseIterable, Identifiable {
    case password
    case identity

    var id: Self { self }

    var title: String {
        switch self {
        case .password:
            "Password"
        case .identity:
            "SSH Key"
        }
    }
}

struct SSHHost: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authentication: SSHAuthenticationKind
    var identityID: UUID?
    var passwordRequiresUserPresence: Bool
    var startsTmux: Bool
    var isFavorite: Bool
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authentication: SSHAuthenticationKind = .password,
        identityID: UUID? = nil,
        passwordRequiresUserPresence: Bool = false,
        startsTmux: Bool = false,
        isFavorite: Bool = false,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authentication = authentication
        self.identityID = identityID
        self.passwordRequiresUserPresence = passwordRequiresUserPresence
        self.startsTmux = startsTmux
        self.isFavorite = isFavorite
        self.lastConnectedAt = lastConnectedAt
    }

    var endpoint: String {
        port == 22 ? hostname : "\(displayHostname):\(port)"
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? hostname : trimmedName
    }

    var normalizedEndpoint: String {
        "\(normalizedDisplayHostname):\(port)"
    }

    static func normalizeHostnameInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              trimmed.hasSuffix("]"),
              trimmed.count > 2 else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    static func isValidHostname(_ value: String) -> Bool {
        let normalized = normalizeHostnameInput(value)
        return !normalized.isEmpty
            && normalized.count <= 253
            && normalized.rangeOfCharacter(
                from: .whitespacesAndNewlines.union(.controlCharacters)
            ) == nil
    }

    private var displayHostname: String {
        hostname.contains(":") ? "[\(hostname)]" : hostname
    }

    private var normalizedDisplayHostname: String {
        let normalized = hostname.lowercased()
        return normalized.contains(":") ? "[\(normalized)]" : normalized
    }
}
