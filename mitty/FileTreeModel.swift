//
//  FileTreeModel.swift
//  mitty
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
    }

    @Published private(set) var rootPath = ""
    @Published private(set) var items: [Item] = []
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
            let alert = NSAlert()
            alert.messageText = "Couldn’t move “\(item.name)” to the Trash."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        rebuild()
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
