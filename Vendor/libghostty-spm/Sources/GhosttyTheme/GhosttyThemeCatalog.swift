//
//  GhosttyThemeCatalog.swift
//  libghostty-spm
//

public enum GhosttyThemeCatalog {
    public static func theme(named name: String) -> GhosttyThemeDefinition? {
        allThemes.first { $0.name == name }
    }

    public static func search(_ query: String) -> [GhosttyThemeDefinition] {
        let lowered = query.lowercased()
        return allThemes.filter { $0.name.lowercased().contains(lowered) }
    }
}
