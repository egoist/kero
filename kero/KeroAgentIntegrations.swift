//
//  KeroAgentIntegrations.swift
//  kero
//

import Foundation

/// Native lifecycle integrations for agent CLIs whose public event surfaces
/// cover an interactive turn. Kero never infers lifecycle state from rendered
/// terminal text, so these events are the only source of blocked and completed
/// transitions. Managed integrations are links into the app bundle so a Kero
/// update cannot leave copied hook/plugin code stale.
enum KeroAgentIntegrations {
    enum Kind: String, CaseIterable {
        case pi
        case opencode
        case grok

        var marker: String { "KERO_INTEGRATION_ID=\(rawValue)" }

        var resource: (name: String, extension: String, directories: [String?]) {
            switch self {
            case .pi:
                return (
                    "kero-agent-state.pi", "txt",
                    ["AgentIntegrations/pi", "pi", nil]
                )
            case .opencode:
                return (
                    "kero-agent-state", "js",
                    ["AgentIntegrations/opencode", "opencode", nil]
                )
            case .grok:
                return (
                    "kero-agent-state.grok", "json",
                    ["AgentIntegrations/grok", "grok", nil]
                )
            }
        }

        var resourceFileName: String {
            let resource = resource
            return "\(resource.name).\(resource.extension)"
        }

        func installationRoot(
            homeURL: URL,
            environment: [String: String]
        ) -> URL {
            switch self {
            case .pi:
                if let configured = environment["PI_CODING_AGENT_DIR"],
                   !configured.isEmpty {
                    return expandedURL(configured, homeURL: homeURL)
                }
                return homeURL.appendingPathComponent(".pi/agent", isDirectory: true)
            case .opencode:
                return homeURL.appendingPathComponent(
                    ".config/opencode",
                    isDirectory: true
                )
            case .grok:
                if let configured = environment["GROK_HOME"],
                   !configured.isEmpty {
                    return expandedURL(configured, homeURL: homeURL)
                }
                return homeURL.appendingPathComponent(".grok", isDirectory: true)
            }
        }

        func destinationURL(
            homeURL: URL,
            environment: [String: String]
        ) -> URL {
            let root = installationRoot(homeURL: homeURL, environment: environment)
            switch self {
            case .pi:
                return root.appendingPathComponent(
                    "extensions/kero-agent-state.ts",
                    isDirectory: false
                )
            case .opencode:
                return root.appendingPathComponent(
                    "plugins/kero-agent-state.js",
                    isDirectory: false
                )
            case .grok:
                return root.appendingPathComponent(
                    "hooks/kero-agent-state.json",
                    isDirectory: false
                )
            }
        }
    }

    enum IntegrationError: Error, LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): message
            }
        }
    }

    /// Validates every integration whose agent config already exists. Missing
    /// agents are intentionally skipped so enabling AI never creates unrelated
    /// provider configuration in the user's home directory.
    static func preflightInstallAvailable(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        for kind in Kind.allCases {
            let root = kind.installationRoot(homeURL: homeURL, environment: environment)
            guard isDirectory(root) else { continue }
            let source = try source(for: kind, bundle: bundle)
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            if itemType(at: destination) != nil,
               !isManaged(destination, kind: kind, sourceURL: source.url) {
                throw IntegrationError.message(
                    "The \(kind.rawValue) integration at \(destination.path) is not managed by Kero."
                )
            }
        }
    }

    static func installAvailable(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try preflightInstallAvailable(
            bundle: bundle,
            homeURL: homeURL,
            environment: environment
        )
        for kind in Kind.allCases {
            let root = kind.installationRoot(homeURL: homeURL, environment: environment)
            guard isDirectory(root) else { continue }
            let source = try source(for: kind, bundle: bundle)
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            if isCurrentLink(destination, sourceURL: source.url) { continue }
            // Recheck ownership after the all-destination preflight so a file
            // changed concurrently is never replaced.
            if itemType(at: destination) != nil,
               !isManaged(destination, kind: kind, sourceURL: source.url) {
                throw IntegrationError.message(
                    "The \(kind.rawValue) integration at \(destination.path) changed while Kero was enabling AI."
                )
            }
            try replaceWithLink(at: destination, sourceURL: source.url)
        }
    }

    static func preflightUninstallManaged(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        for kind in Kind.allCases {
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            guard itemType(at: destination) != nil else { continue }
            guard isManaged(destination, kind: kind, sourceURL: nil) else {
                throw IntegrationError.message(
                    "The \(kind.rawValue) integration at \(destination.path) has local changes."
                )
            }
        }
    }

    static func uninstallManaged(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try preflightUninstallManaged(homeURL: homeURL, environment: environment)
        for kind in Kind.allCases {
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            if itemType(at: destination) != nil {
                try FileManager.default.removeItem(at: destination)
            }
        }
    }

    private struct Source {
        let url: URL
    }

    private static func source(for kind: Kind, bundle: Bundle) throws -> Source {
        let resource = kind.resource
        for directory in resource.directories {
            guard let url = bundle.url(
                forResource: resource.name,
                withExtension: resource.extension,
                subdirectory: directory
            ) else { continue }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8),
                  text.contains(kind.marker) else { continue }
            return Source(url: url.standardizedFileURL)
        }
        throw IntegrationError.message(
            "Kero's bundled \(kind.rawValue) lifecycle integration is missing."
        )
    }

    private static func isManaged(
        _ url: URL,
        kind: Kind,
        sourceURL: URL?
    ) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= 256 * 1_024,
              let text = String(data: data, encoding: .utf8)
        else {
            // A moved or replaced app can leave Kero's absolute resource link
            // temporarily dangling. Recognize only its exact resource name
            // beneath an app bundle so launch reconciliation can repair it.
            guard itemType(at: url) == .typeSymbolicLink,
                  let target = symbolicLinkTarget(at: url),
                  target.lastPathComponent == kind.resourceFileName,
                  target.path.contains(".app/Contents/Resources/")
            else { return false }
            return true
        }
        if text.contains(kind.marker) { return true }
        guard let sourceURL else { return false }
        return isCurrentLink(url, sourceURL: sourceURL)
    }

    private static func isCurrentLink(_ url: URL, sourceURL: URL) -> Bool {
        guard itemType(at: url) == .typeSymbolicLink,
              let target = symbolicLinkTarget(at: url)
        else { return false }
        return target.standardizedFileURL.path == sourceURL.standardizedFileURL.path
    }

    private static func symbolicLinkTarget(at url: URL) -> URL? {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(
            atPath: url.path
        ) else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return url.deletingLastPathComponent().appendingPathComponent(path)
    }

    private static func replaceWithLink(at destination: URL, sourceURL: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let stem = destination.lastPathComponent
        let staging = parent.appendingPathComponent(
            ".\(stem).kero-staging-\(UUID().uuidString)"
        )
        let backup = parent.appendingPathComponent(
            ".\(stem).kero-backup-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createSymbolicLink(
            atPath: staging.path,
            withDestinationPath: sourceURL.standardizedFileURL.path
        )

        let existed = itemType(at: destination) != nil
        if existed {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if existed, itemType(at: destination) == nil {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        if existed { try? fileManager.removeItem(at: backup) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func itemType(at url: URL) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType
    }

    private static func expandedURL(_ path: String, homeURL: URL) -> URL {
        if path == "~" { return homeURL }
        if path.hasPrefix("~/") {
            return homeURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
