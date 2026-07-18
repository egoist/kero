//
//  SessionStore.swift
//  mitty
//

import Foundation

/// Snapshot of open projects and tabs, saved so a relaunch restores the
/// previous layout. Terminal sessions restore as fresh shells started in
/// their last known working directory; file and diff tabs reload from disk.
struct SessionSnapshot: Codable {
    struct ProjectSnapshot: Codable {
        enum Tab: Codable {
            case session(workingDirectory: String)
            case file(path: String)
            case diff(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?)
        }

        var customName: String?
        var tabs: [Tab]
        var selectedTabIndex: Int?
    }

    var projects: [ProjectSnapshot]
    var selectedProjectIndex: Int?
}

enum SessionStore {
    private static let key = "sessionSnapshot"

    static func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
