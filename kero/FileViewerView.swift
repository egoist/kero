//
//  FileViewerView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// A file opened as a tab in a project. Text content lives here (not in the
/// view) so edits survive tab switches.
@MainActor
final class FileTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()
    /// Mutable so a rename in the file tree can re-point the tab without
    /// tearing it down (the id — hence the editor and its state — is stable).
    @Published private(set) var path: String

    enum Content {
        case text
        case image(NSImage)
        case unavailable(String)
    }

    private(set) var content: Content
    /// Current editor text, written back by the editor on every edit. Not
    /// published: the editor owns display, this is only read back for saves.
    var text: String
    /// The content as last loaded from or saved to disk. `isDirty` is the
    /// difference between this and `text`, so undoing edits back to it (or
    /// retyping the same characters) clears the dirty indicator rather than
    /// leaving it stuck on.
    private var savedText = ""
    /// Scroll position and cursor, written back by the editor as they
    /// change. Lives here (not in the view) so the state survives tab
    /// switches, and in the session snapshot so it survives relaunches. Not
    /// published for the same reason as `text`.
    var editorState = EditorState()

    @Published private(set) var isDirty = false
    @Published var saveError: String?
    /// Changes only when a clean tab picks up different bytes from disk. Text
    /// editors use this as their identity so an already-mounted pane is rebuilt
    /// with the new content while preserving its stored cursor/scroll state.
    @Published private(set) var reloadRevision: UInt = 0

    /// The editor's scroll view while this file is on screen, so a pane-move
    /// drag can snapshot it for the drag thumbnail. Weak — owned by the mounted
    /// editor, nils out when the pane unmounts.
    weak var editorView: NSView?

    private nonisolated static let maxTextBytes = 5 << 20
    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "icns",
    ]
    private var imageFingerprint: Int?
    private var reloadGeneration: UInt = 0
    private var reloadTask: Task<Void, Never>?

    private struct LoadedContent {
        let content: Content
        let text: String
        let imageFingerprint: Int?
    }

    init(path: String) {
        self.path = path
        let loaded = Self.load(path: path)
        content = loaded.content
        text = loaded.text
        savedText = loaded.text
        imageFingerprint = loaded.imageFingerprint
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    /// Re-points this tab at a new location after the file (or a directory
    /// above it) was renamed on disk. The bytes are unchanged, so nothing
    /// reloads; subsequent saves write to the new path.
    func updatePath(_ newPath: String) {
        guard newPath != path else { return }
        invalidateReload()
        path = newPath
    }

    /// Recompute `isDirty` from the current `text` against the saved
    /// baseline. Called after every editor change (including undo/redo), so
    /// reverting to the saved content clears the dirty state.
    func refreshDirtyState() {
        let dirty: Bool
        if case .text = content {
            dirty = text != savedText
        } else {
            dirty = false
        }
        if isDirty != dirty {
            isDirty = dirty
            if dirty {
                // A read started while the buffer was clean must never replace
                // an edit that happened before that read completed.
                invalidateReload()
            }
        }
    }

    func save() {
        guard case .text = content, isDirty else { return }
        invalidateReload()
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            savedText = text
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Re-read a clean preview when it returns on screen. Disk I/O happens off
    /// the main actor; generation/path/dirty guards keep an older read from
    /// winning over a rename, save, or edit performed while it was in flight.
    func reloadFromDiskIfClean() {
        guard !isDirty else { return }
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let expectedPath = path

        reloadTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                Self.readData(path: expectedPath)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.reloadGeneration == generation,
                  self.path == expectedPath,
                  !self.isDirty
            else { return }

            let loaded = Self.loadedContent(path: expectedPath, data: data)
            guard !self.matches(loaded) else { return }
            self.content = loaded.content
            self.text = loaded.text
            self.savedText = loaded.text
            self.imageFingerprint = loaded.imageFingerprint
            self.saveError = nil
            self.reloadRevision &+= 1
        }
    }

    private func invalidateReload() {
        reloadTask?.cancel()
        reloadTask = nil
        reloadGeneration &+= 1
    }

    private func matches(_ loaded: LoadedContent) -> Bool {
        switch (content, loaded.content) {
        case (.text, .text):
            return savedText == loaded.text
        case (.image, .image):
            return imageFingerprint == loaded.imageFingerprint
        case (.unavailable(let current), .unavailable(let new)):
            return current == new
        default:
            return false
        }
    }

    private static func load(path: String) -> LoadedContent {
        loadedContent(path: path, data: readData(path: path))
    }

    private nonisolated static func readData(path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func loadedContent(path: String, data: Data?) -> LoadedContent {
        let url = URL(fileURLWithPath: path)
        guard let data else {
            return LoadedContent(
                content: .unavailable(String(localized: "Could not read file")),
                text: "",
                imageFingerprint: nil
            )
        }
        if imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(data: data) {
            return LoadedContent(
                content: .image(image),
                text: "",
                imageFingerprint: data.hashValue
            )
        }
        guard data.count <= maxTextBytes else {
            return LoadedContent(
                content: .unavailable(String(localized: "File is too large to open")),
                text: "",
                imageFingerprint: nil
            )
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return LoadedContent(
                content: .unavailable(String(localized: "Binary file")),
                text: "",
                imageFingerprint: nil
            )
        }
        return LoadedContent(content: .text, text: string, imageFingerprint: nil)
    }
}

/// Content of a file tab: an STTextView editor (line numbers, system find
/// bar), an image preview, or a placeholder for anything binary or
/// oversized.
struct FileViewerView: View {
    @ObservedObject var file: FileTab
    /// Whether this file's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the editor takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }
    var onNewBrowserTab: (String?) -> Void = { _ in }
    var onNewBrowserPane: (String?) -> Void = { _ in }

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch file.content {
            case .text:
                VStack(spacing: 0) {
                    if let error = file.saveError {
                        saveErrorBar(error)
                    }
                    SourceTextEditor(
                        file: file,
                        font: TerminalFont.current(),
                        palette: .theme(dark: colorScheme == .dark),
                        wrapLines: settings.wrapLines,
                        isFocused: isFocused,
                        onFocused: onFocused,
                        onSplit: onSplit,
                        onNewBrowserTab: onNewBrowserTab,
                        onNewBrowserPane: onNewBrowserPane
                    )
                    .id(file.reloadRevision)
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .padding(16)
                }
            case .unavailable(let reason):
                VStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            file.reloadFromDiskIfClean()
        }
        // The selected file view stays mounted while Kero is inactive, so
        // returning from an external editor does not trigger `onAppear`.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            file.reloadFromDiskIfClean()
        }
        // A window can become key without the app itself transitioning from
        // inactive (for example when moving between Kero windows).
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in
            file.reloadFromDiskIfClean()
        }
    }

    private func saveErrorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text("Could not save: \(message)")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }
}
