import Foundation
import LocalAuthentication
import Security

enum KeychainStoreError: LocalizedError {
    case accessControlCreationFailed
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .accessControlCreationFailed:
            "Kero could not create the requested Keychain protection."
        case .unexpectedStatus(let status):
            switch status {
            case errSecUserCanceled:
                "Authentication was canceled."
            case errSecAuthFailed:
                "Face ID or device authentication failed."
            case errSecItemNotFound:
                "The saved credential could not be found."
            case errSecInteractionNotAllowed:
                "Unlock this device before using the saved credential."
            default:
                SecCopyErrorMessageString(status, nil) as String?
                    ?? "The Keychain returned error \(status)."
            }
        case .invalidData:
            "The saved credential is invalid."
        }
    }
}

final class KeychainStore {
    private let service: String

    init(service: String = "sh.kero.mobile") {
        self.service = service
    }

    func save(
        _ data: Data,
        account: String,
        requiresUserPresence: Bool
    ) throws {
        try delete(account: account, ignoringMissingItem: true)

        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecUseDataProtectionKeychain: true
        ]

        if requiresUserPresence {
            var error: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                throw error?.takeRetainedValue()
                    ?? KeychainStoreError.accessControlCreationFailed
            }
            attributes[kSecAttrAccessControl] = accessControl
        } else {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func read(account: String, reason: String) throws -> Data {
        try Self.read(
            service: service,
            account: account,
            reason: reason
        )
    }

    func readAsync(account: String, reason: String) async throws -> Data {
        let service = service
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try Self.read(
                            service: service,
                            account: account,
                            reason: reason
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func read(
        service: String,
        account: String,
        reason: String
    ) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
            kSecUseDataProtectionKeychain: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.invalidData
        }
        return data
    }

    func contains(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) throws {
        try delete(account: account, ignoringMissingItem: false)
    }

    func deleteIfPresent(account: String) throws {
        try delete(account: account, ignoringMissingItem: true)
    }

    private func delete(account: String, ignoringMissingItem: Bool) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || (ignoringMissingItem && status == errSecItemNotFound) else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}
