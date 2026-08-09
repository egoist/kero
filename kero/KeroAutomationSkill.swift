//
//  KeroAutomationSkill.swift
//  kero
//

import Foundation

/// Loads Kero's canonical Agent Skill from the app bundle and manages
/// user-scoped discovery links. The shared `.agents` destination covers Codex,
/// Gemini, Grok, Cursor, OpenCode, Amp, and Pi; Claude currently requires its
/// own root.
enum KeroAutomationSkill {
    static let name = "kero-automation"

    enum Destination: String, CaseIterable {
        case universal
        case claude

        var relativeDirectory: String {
            switch self {
            case .universal: ".agents/skills/\(KeroAutomationSkill.name)"
            case .claude: ".claude/skills/\(KeroAutomationSkill.name)"
            }
        }

        var agents: [String] {
            switch self {
            case .universal: [
                "codex", "gemini", "grok", "cursor", "opencode", "amp", "pi",
            ]
            case .claude: ["claude"]
            }
        }
    }

    enum InstallationState: String {
        case missing
        case current
        case updateAvailable = "update_available"
        case unmanaged
        case modified
    }

    struct Snapshot {
        let destination: Destination
        let url: URL
        let state: InstallationState
    }

    struct MutationResult {
        let destination: Destination
        let url: URL
        let previousState: InstallationState
        let state: InstallationState
    }

    enum SkillError: Error, LocalizedError, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let message): message
            }
        }

        var errorDescription: String? { description }
    }

    private struct Source {
        let skillURL: URL
        let files: [String: URL]

        var links: [String: String] {
            files.mapValues { $0.standardizedFileURL.path }
        }
    }

    private struct Manifest: Codable {
        let formatVersion: Int
        let skill: String
        let links: [String: String]

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case skill
            case links
        }
    }

    private static let manifestName = ".kero-managed.json"

    static func bundledSkillURL() throws -> URL {
        try source().skillURL
    }

    static func bundledSkillText() throws -> String {
        let source = try source()
        guard let skillURL = source.files["SKILL.md"] else {
            throw SkillError.message("Kero's bundled automation SKILL.md is missing.")
        }
        let data = try Data(contentsOf: skillURL)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SkillError.message("Kero's bundled automation skill is not valid UTF-8.")
        }
        return text
    }

    static func destinations(for provider: String) throws -> [Destination] {
        switch provider.lowercased() {
        case "all":
            return Destination.allCases
        case "universal", "agents", "codex", "gemini", "grok", "cursor",
             "cursor-agent", "opencode", "amp", "pi":
            return [.universal]
        case "claude":
            return [.claude]
        default:
            throw SkillError.message(
                "Unsupported skill provider \(provider.debugDescription). "
                    + "Use all, universal, codex, claude, gemini, grok, cursor, "
                    + "opencode, amp, or pi."
            )
        }
    }

    static func status(
        destinations: [Destination],
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [Snapshot] {
        let source = try source()
        return try unique(destinations).map {
            try snapshot(for: $0, source: source, homeURL: homeURL)
        }
    }

    static func install(
        destinations: [Destination],
        force: Bool,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [MutationResult] {
        let source = try source()
        let existing = try unique(destinations).map {
            try snapshot(for: $0, source: source, homeURL: homeURL)
        }
        if let conflict = existing.first(where: { $0.state == .modified }), !force {
            throw SkillError.message(
                "The skill at \(conflict.url.path) has local changes. "
                    + "Re-run with --force to replace it."
            )
        }

        return try existing.map { item in
            if item.state != .current {
                try replaceSkill(at: item.url, source: source)
            }
            return MutationResult(
                destination: item.destination,
                url: item.url,
                previousState: item.state,
                state: .current
            )
        }
    }

    static func uninstall(
        destinations: [Destination],
        force: Bool,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [MutationResult] {
        let source = try source()
        let existing = try unique(destinations).map {
            try snapshot(for: $0, source: source, homeURL: homeURL)
        }
        if let conflict = existing.first(where: {
            $0.state == .modified || $0.state == .unmanaged
        }), !force {
            throw SkillError.message(
                "The skill at \(conflict.url.path) is not safely managed by Kero. "
                    + "Re-run with --force to remove it."
            )
        }

        return try existing.map { item in
            if item.state != .missing {
                try FileManager.default.removeItem(at: item.url)
            }
            return MutationResult(
                destination: item.destination,
                url: item.url,
                previousState: item.state,
                state: .missing
            )
        }
    }

    private static func source(bundle: Bundle = .main) throws -> Source {
        guard let skillURL = bundledURL(
            name: "SKILL",
            extension: "md",
            subdirectories: ["Skills/\(name)", name, nil],
            bundle: bundle
        ) else {
            throw SkillError.message("Kero's bundled automation SKILL.md is missing.")
        }
        guard let metadataURL = bundledURL(
            name: "openai",
            extension: "yaml",
            subdirectories: ["Skills/\(name)/agents", "\(name)/agents", "agents", nil],
            bundle: bundle
        ) else {
            throw SkillError.message("Kero's bundled automation skill metadata is missing.")
        }
        guard isRegularFile(skillURL), isRegularFile(metadataURL) else {
            throw SkillError.message("Kero's bundled automation skill resources are not files.")
        }

        let skillData = try Data(contentsOf: skillURL)
        guard String(data: skillData, encoding: .utf8)?.contains("name: \(name)") == true else {
            throw SkillError.message("Kero's bundled automation SKILL.md has unexpected contents.")
        }
        return Source(
            skillURL: skillURL,
            files: [
                "SKILL.md": skillURL,
                "agents/openai.yaml": metadataURL,
            ]
        )
    }

    private static func bundledURL(
        name: String,
        extension fileExtension: String,
        subdirectories: [String?],
        bundle: Bundle
    ) -> URL? {
        for subdirectory in subdirectories {
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }

    private static func snapshot(
        for destination: Destination,
        source: Source,
        homeURL: URL
    ) throws -> Snapshot {
        let url = homeURL.appendingPathComponent(destination.relativeDirectory, isDirectory: true)
        guard let rootType = itemType(at: url) else {
            return Snapshot(destination: destination, url: url, state: .missing)
        }
        guard rootType == .typeDirectory else {
            return Snapshot(destination: destination, url: url, state: .modified)
        }

        let manifestURL = url.appendingPathComponent(manifestName)
        if isRegularFile(manifestURL),
           let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.formatVersion == 2,
           manifest.skill == name {
            let expectedEntries = expectedEntries(
                paths: manifest.links.keys,
                includesManifest: true
            )
            if try treeEntries(at: url) == expectedEntries,
               let links = try symbolicLinks(at: url, paths: manifest.links.keys),
               links == manifest.links {
                let state: InstallationState = manifest.links == source.links
                    ? .current
                    : .updateAvailable
                return Snapshot(destination: destination, url: url, state: state)
            }
            return Snapshot(destination: destination, url: url, state: .modified)
        }

        let sourceLinks = source.links
        let entries = try treeEntries(at: url)
        let links = try symbolicLinks(at: url, paths: sourceLinks.keys)
        let isUnmanagedMatch = entries == expectedEntries(
            paths: sourceLinks.keys,
            includesManifest: false
        ) && links == sourceLinks
        let state: InstallationState = isUnmanagedMatch ? .unmanaged : .modified
        return Snapshot(destination: destination, url: url, state: state)
    }

    private static func expectedEntries(
        paths: Dictionary<String, String>.Keys,
        includesManifest: Bool
    ) -> Set<String> {
        var allowed = Set(paths)
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            components.removeLast()
            while !components.isEmpty {
                allowed.insert(components.joined(separator: "/"))
                components.removeLast()
            }
        }
        if includesManifest { allowed.insert(manifestName) }
        return allowed
    }

    private static func symbolicLinks(
        at root: URL,
        paths: Dictionary<String, String>.Keys
    ) throws -> [String: String]? {
        let fileManager = FileManager.default
        var result: [String: String] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                return nil
            }
            result[path] = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        }
        return result
    }

    private static func treeEntries(at root: URL) throws -> Set<String> {
        var result: Set<String> = []
        try collectEntries(at: root, prefix: "", into: &result)
        return result
    }

    private static func collectEntries(
        at directory: URL,
        prefix: String,
        into result: inout Set<String>
    ) throws {
        let fileManager = FileManager.default
        for child in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            // Build logical relative paths from names rather than absolute
            // string prefixes. Foundation can return `/private/tmp` child
            // URLs for a `/tmp` root even when resolving symlinks leaves the
            // root spelling unchanged.
            let relative = prefix.isEmpty
                ? child.lastPathComponent
                : "\(prefix)/\(child.lastPathComponent)"
            result.insert(relative)
            let attributes = try fileManager.attributesOfItem(atPath: child.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                try collectEntries(at: child, prefix: relative, into: &result)
            }
        }
    }

    private static func replaceSkill(at destination: URL, source: Source) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let staging = parent.appendingPathComponent(
            ".\(name).kero-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".\(name).kero-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        try writeSkill(at: staging, source: source)
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

    private static func writeSkill(at destination: URL, source: Source) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        for (path, target) in source.files {
            let url = destination.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try fileManager.createSymbolicLink(
                atPath: url.path,
                withDestinationPath: target.standardizedFileURL.path
            )
        }

        let manifest = Manifest(formatVersion: 2, skill: name, links: source.links)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestURL = destination.appendingPathComponent(manifestName)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: manifestURL.path
        )
    }

    private static func unique(_ destinations: [Destination]) -> [Destination] {
        var seen: Set<Destination> = []
        return destinations.filter { seen.insert($0).inserted }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        itemType(at: url) == .typeRegular
    }

    private static func itemType(at url: URL) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType
    }

}
