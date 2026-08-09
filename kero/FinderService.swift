//
//  FinderService.swift
//  kero
//

import AppKit

/// Provides Kero's Finder service. The advertised menu item lives in
/// Info.plist; AppKit forwards matching service requests to this object.
@MainActor
final class KeroApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    /// Opens every directory Finder placed on the service pasteboard as a
    /// project in the active Kero window.
    @objc func openInKero(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let directories = Self.directories(from: pasteboard)
        guard !directories.isEmpty else {
            error.pointee = String(localized: "Select one or more folders to open in Kero.") as NSString
            return
        }

        NSApp.activate()
        TerminalManager.openDirectories(directories)
    }

    private static func directories(from pasteboard: NSPasteboard) -> [String] {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        var candidates = pasteboard.propertyList(forType: filenamesType) as? [String] ?? []

        if candidates.isEmpty,
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL] {
            candidates = urls.map(\.path)
        }

        if candidates.isEmpty, let text = pasteboard.string(forType: .string) {
            candidates = text.split(whereSeparator: \.isNewline).map(String.init)
        }

        let fileManager = FileManager.default
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let path: String
            if let url = URL(string: candidate), url.isFileURL {
                path = url.path
            } else {
                path = (candidate as NSString).expandingTildeInPath
            }

            let standardized = URL(
                fileURLWithPath: path,
                isDirectory: true
            ).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: standardized,
                isDirectory: &isDirectory
            ), isDirectory.boolValue, seen.insert(standardized).inserted else {
                return nil
            }
            return standardized
        }
    }
}
