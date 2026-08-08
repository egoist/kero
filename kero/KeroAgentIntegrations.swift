//
//  KeroAgentIntegrations.swift
//  kero
//

import Foundation

/// Native lifecycle integrations for agent CLIs whose public event surfaces
/// cover a full interactive turn. Other supported agents continue to use
/// process identity plus screen detection; partial hooks must never override
/// that more complete lifecycle source.
enum KeroAgentIntegrations {
    enum Kind: String, CaseIterable {
        case pi
        case opencode

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
            }
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
            _ = try source(for: kind, bundle: bundle)
            let destination = kind.destinationURL(
                homeURL: homeURL,
                environment: environment
            )
            if FileManager.default.fileExists(atPath: destination.path),
               !isManaged(destination, kind: kind) {
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
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.data.write(to: destination, options: .atomic)
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
            guard FileManager.default.fileExists(atPath: destination.path) else { continue }
            guard isManaged(destination, kind: kind) else {
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
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
        }
    }

    private struct Source {
        let data: Data
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
            return Source(data: data)
        }
        throw IntegrationError.message(
            "Kero's bundled \(kind.rawValue) lifecycle integration is missing."
        )
    }

    private static func isManaged(_ url: URL, kind: Kind) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= 256 * 1_024,
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains(kind.marker)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func expandedURL(_ path: String, homeURL: URL) -> URL {
        if path == "~" { return homeURL }
        if path.hasPrefix("~/") {
            return homeURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
