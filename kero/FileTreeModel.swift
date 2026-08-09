//
//  FileTreeModel.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// Flattened, lazily-expanded view of a directory tree.
@MainActor
final class FileTreeModel: nonisolated ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        /// True for the transient inline "new file/folder" input row, which
        /// has no backing file yet.
        var isDraft = false
    }

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    struct Draft: Equatable {
        let parentDir: String
        let isDirectory: Bool
    }

    @Published private(set) var rootPath = ""
    @Published private(set) var items: [Item] = []
    /// Path of the row currently being renamed inline, if any.
    @Published private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    @Published private(set) var draft: Draft?
    private var expanded: Set<String> = []

    var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    /// Points the tree at `root` (collapsing everything if it moved) and
    /// re-reads visible directories. Cheap when nothing changed.
    func sync(root: String) {
        if root != rootPath {
            rootPath = root
            expanded = []
            // Any in-progress inline edit belonged to the old tree.
            renamingPath = nil
            draft = nil
        }
        rebuild()
    }

    func toggle(_ item: Item) {
        guard item.isDirectory else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        rebuild()
    }

    /// Moves `item` to the Trash, then rebuilds so it drops out of the tree.
    func moveToTrash(_ item: Item) {
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: item.path), resultingItemURL: nil
            )
            expanded.remove(item.path)
        } catch {
            presentError(
                String(
                    localized: "Couldn’t move “\(item.name)” to the Trash.",
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
        rebuild()
    }

    // MARK: - Rename

    func beginRename(_ item: Item) {
        renamingPath = item.path
    }

    func cancelRename() {
        renamingPath = nil
    }

    /// Renames `item` in place. No-ops on an empty or unchanged name; shows an
    /// alert if the name collides or the filesystem move fails. Returns the new
    /// absolute path when the file actually moved, so callers can follow it
    /// (e.g. re-point open tabs).
    @discardableResult
    func rename(_ item: Item, to newName: String) -> String? {
        renamingPath = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”."),
                String(localized: "A name can’t contain “/” or be “.” or “..”.")
            )
            return nil
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        // A case-only rename ("foo"→"Foo") maps to the same file on a
        // case-insensitive volume, so don't treat that as a collision.
        let caseOnlyChange = trimmed.lowercased() == item.name.lowercased()
        guard caseOnlyChange || !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”."),
                String(localized: "An item named “\(trimmed)” already exists here.")
            )
            return nil
        }
        do {
            try fm.moveItem(atPath: item.path, toPath: dest)
            remapExpanded(from: item.path, to: dest)
        } catch {
            presentError(String(localized: "Couldn’t rename to “\(trimmed)”."), error.localizedDescription)
            return nil
        }
        rebuild()
        return dest
    }

    /// Keeps expansion state after a directory rename by rewriting the old
    /// path prefix (for the folder itself and any expanded descendants).
    private func remapExpanded(from oldPath: String, to newPath: String) {
        guard expanded.contains(where: { $0 == oldPath || $0.hasPrefix(oldPath + "/") })
        else { return }
        expanded = Set(expanded.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") {
                return newPath + String(path.dropFirst(oldPath.count))
            }
            return path
        })
    }

    // MARK: - Create (inline draft)

    /// Opens an inline input row for a new file inside `directory`.
    func beginNewFile(in directory: String) {
        startDraft(in: directory, isDirectory: false)
    }

    /// Opens an inline input row for a new folder inside `directory`.
    func beginNewFolder(in directory: String) {
        startDraft(in: directory, isDirectory: true)
    }

    private func startDraft(in directory: String, isDirectory: Bool) {
        renamingPath = nil
        draft = Draft(parentDir: directory, isDirectory: isDirectory)
        // Reveal the folder's contents so the input row is visible.
        expanded.insert(directory)
        rebuild()
    }

    func cancelDraft() {
        guard draft != nil else { return }
        draft = nil
        rebuild()
    }

    /// Commits the pending draft, creating the file or folder. An empty name
    /// cancels (matching VS Code). Returns the new file's path — for files
    /// only — so the caller can open it.
    @discardableResult
    func commitDraft(name: String) -> String? {
        guard let draft else { return nil }
        self.draft = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { rebuild(); return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”."),
                String(localized: "A name can’t contain “/” or be “.” or “..”.")
            )
            rebuild()
            return nil
        }
        let dest = (draft.parentDir as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest) else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”."),
                String(localized: "An item named “\(trimmed)” already exists here.")
            )
            rebuild()
            return nil
        }
        var createdFile: String?
        if draft.isDirectory {
            do {
                try fm.createDirectory(atPath: dest, withIntermediateDirectories: false)
            } catch {
                presentError(String(localized: "Couldn’t create the folder."), error.localizedDescription)
            }
        } else if fm.createFile(atPath: dest, contents: nil) {
            createdFile = dest
        } else {
            presentError(
                String(localized: "Couldn’t create the file."),
                String(localized: "It could not be written to disk.")
            )
        }
        rebuild()
        return createdFile
    }

    private func presentError(_ messageText: String, _ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func rebuild() {
        guard !rootPath.isEmpty else { return }
        var out: [Item] = []
        appendChildren(of: rootPath, depth: 0, into: &out)
        if out != items {
            items = out
        }
    }

    private func appendChildren(of dir: String, depth: Int, into out: inout [Item]) {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return }
        // Show the inline new-file/folder input at the top of its folder.
        if let draft, draft.parentDir == dir {
            out.append(
                Item(
                    name: "", path: dir + "/\u{1}draft",
                    isDirectory: draft.isDirectory, depth: depth, isDraft: true
                )
            )
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }

        let children = names
            .filter { $0 != ".git" }
            .map { name -> Item in
                let path = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                return Item(name: name, path: path, isDirectory: isDir.boolValue, depth: depth)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        for child in children {
            out.append(child)
            if child.isDirectory, expanded.contains(child.path) {
                appendChildren(of: child.path, depth: depth + 1, into: &out)
            }
        }
    }
}
