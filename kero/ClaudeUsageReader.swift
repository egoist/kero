//
//  ClaudeUsageReader.swift
//  kero
//

import Foundation
import Security

/// Reads Claude Code plan usage from Anthropic's OAuth usage endpoint.
///
/// Unlike Codex, Claude Code keeps no local record of its rate-limit windows —
/// transcripts carry token counts but not plan utilization — so the numbers
/// have to be fetched, reusing the token the CLI already stores.
///
/// The token lives in `~/.claude/.credentials.json` on some installs and in
/// the login keychain (service `Claude Code-credentials`) on others. Reading
/// the keychain item prompts for permission the first time because kero isn't
/// the app that created it, which is why the caller gates this behind an
/// explicit opt-in rather than polling on launch.
nonisolated enum ClaudeUsageReader {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "claude-code/2.1.0"
    private static let keychainService = "Claude Code-credentials"

    // MARK: - Errors

    enum ReaderError: LocalizedError, Equatable {
        case notSignedIn
        case keychainAccessDenied
        case tokenExpired
        case unauthorized
        /// Carries Anthropic's own `Retry-After` when it sends one, so the
        /// backoff matches what the server asked for instead of guessing.
        case rateLimited(retryAfter: Date?)
        case server(Int)
        case network(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "No Claude credentials found. Run `claude` and sign in."
            case .keychainAccessDenied:
                "kero needs permission to read the Claude Code keychain item."
            case .tokenExpired:
                "Claude login expired. Run `claude` to refresh it."
            case .unauthorized:
                "Claude rejected the stored token. Run `claude` to sign in again."
            case let .rateLimited(retryAfter):
                if let retryAfter, retryAfter > Date() {
                    "Anthropic is rate limiting usage checks. Try again in "
                        + AgentUsage.durationLabel(retryAfter.timeIntervalSinceNow) + "."
                } else {
                    "Anthropic is rate limiting usage checks. Try again in a few minutes."
                }
            case let .server(code):
                "Anthropic returned HTTP \(code)."
            case let .network(message):
                "Network error: \(message)"
            case .malformedResponse:
                "Could not read Anthropic's usage response."
            }
        }

        /// Whether retrying — possibly after a permission grant — could work.
        var isRecoverable: Bool {
            switch self {
            case .keychainAccessDenied, .rateLimited, .network, .server:
                true
            case .notSignedIn, .tokenExpired, .unauthorized, .malformedResponse:
                false
            }
        }
    }

    // MARK: - Entry point

    static func fetchSnapshot() async throws -> AgentUsageSnapshot {
        let credentials = try loadCredentials()
        if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
            // Refreshing would rotate the token the CLI itself depends on, so
            // kero reports the expiry and lets Claude Code own its own login.
            throw ReaderError.tokenExpired
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReaderError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ReaderError.malformedResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ReaderError.unauthorized
        case 429:
            throw ReaderError.rateLimited(retryAfter: retryAfterDate(from: http))
        default:
            throw ReaderError.server(http.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReaderError.malformedResponse
        }
        var snapshot = parse(object)
        snapshot.planLabel = credentials.subscriptionType?.capitalized
        return snapshot
    }

    // MARK: - Response parsing

    private static func parse(_ object: [String: Any]) -> AgentUsageSnapshot {
        var snapshot = AgentUsageSnapshot(provider: .claude)
        snapshot.sourceLabel = "Anthropic OAuth usage API"

        // Older shape: one key per window.
        let named: [(key: String, label: String)] = [
            ("five_hour", "5h limit"),
            ("seven_day", "Weekly limit"),
            ("seven_day_opus", "Weekly (Opus)"),
            ("seven_day_sonnet", "Weekly (Sonnet)"),
        ]
        var windows: [AgentUsageWindow] = named.compactMap { entry in
            guard let raw = object[entry.key] as? [String: Any] else { return nil }
            return window(from: raw, label: entry.label)
        }

        // Newer shape: a flat `limits` array where weekly caps name the model
        // they scope to. Entries here supersede same-labelled keys above.
        if let limits = object["limits"] as? [[String: Any]] {
            for limit in limits {
                guard limit["is_active"] as? Bool != false,
                      let percent = limit["percent"] as? Double
                else { continue }
                let scopedModel = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let group = (limit["group"] as? String) ?? (limit["kind"] as? String) ?? "limit"
                let label: String = if let scopedModel, !scopedModel.isEmpty {
                    "\(group.capitalized) (\(scopedModel))"
                } else {
                    "\(group.capitalized) limit"
                }
                let resetsAt = parseDate(limit["resets_at"] as? String)
                windows.removeAll { $0.label == label }
                windows.append(
                    AgentUsageWindow(label: label, usedPercent: percent, resetsAt: resetsAt)
                )
            }
        }

        snapshot.windows = windows
        return snapshot
    }

    private static func window(from raw: [String: Any], label: String) -> AgentUsageWindow? {
        guard let utilization = raw["utilization"] as? Double else { return nil }
        return AgentUsageWindow(
            label: label,
            usedPercent: utilization,
            resetsAt: parseDate(raw["resets_at"] as? String)
        )
    }

    /// `Retry-After` is either a delay in seconds or an HTTP date.
    private static func retryAfterDate(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: - Credentials

    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
    }

    /// File first — it never prompts — then the login keychain.
    static func loadCredentials() throws -> Credentials {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL),
           let credentials = decode(data) {
            return credentials
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let credentials = decode(data) else {
                throw ReaderError.notSignedIn
            }
            return credentials
        case errSecItemNotFound:
            throw ReaderError.notSignedIn
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired:
            throw ReaderError.keychainAccessDenied
        default:
            throw ReaderError.keychainAccessDenied
        }
    }

    private static func decode(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        // `expiresAt` is milliseconds since epoch.
        let expiresAt = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return Credentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
