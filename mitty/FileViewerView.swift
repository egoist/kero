//
//  FileViewerView.swift
//  mitty
//

import AppKit
import CodeEditLanguages
import Combine
import CodeEditSourceEditor
import SwiftUI

/// A file opened as a tab in a project. Text content lives here (not in the
/// view) so edits survive tab switches.
@MainActor
final class FileTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()
    let path: String

    enum Content {
        case text
        case image(NSImage)
        case unavailable(String)
    }

    let content: Content
    /// tree-sitter language for syntax highlighting; `.default` is plain text.
    let language: CodeLanguage
    /// Current editor text, written back by the editor on every edit. Not
    /// published: the editor owns display, this is only read back for saves.
    var text: String

    @Published private(set) var isDirty = false
    @Published var saveError: String?

    private static let maxTextBytes = 5 << 20
    /// Above this size skip tree-sitter parsing; edit as plain text.
    private static let maxHighlightBytes = 2 << 20
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "icns",
    ]

    init(path: String) {
        self.path = path
        let url = URL(fileURLWithPath: path)
        if Self.imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            content = .image(image)
            language = .default
            text = ""
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            content = .unavailable("Could not read file")
            language = .default
            text = ""
            return
        }
        guard data.count <= Self.maxTextBytes else {
            content = .unavailable("File is too large to open")
            language = .default
            text = ""
            return
        }
        guard let string = String(data: data, encoding: .utf8) else {
            content = .unavailable("Binary file")
            language = .default
            text = ""
            return
        }
        content = .text
        text = string
        language = data.count <= Self.maxHighlightBytes
            ? CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(string.prefix(512)))
            : .default
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    func markDirty() {
        if !isDirty {
            isDirty = true
        }
    }

    func save() {
        guard case .text = content, isDirty else { return }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Content of a file tab: a CodeEditSourceEditor (tree-sitter highlighting,
/// line numbers), an image preview, or a placeholder for anything binary or
/// oversized.
struct FileViewerView: View {
    @ObservedObject var file: FileTab

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorState = SourceEditorState()
    @State private var findPanelFix = FindPanelClickFixCoordinator()

    var body: some View {
        switch file.content {
        case .text:
            VStack(spacing: 0) {
                if let error = file.saveError {
                    saveErrorBar(error)
                }
                SourceEditor(
                    textBinding,
                    language: file.language,
                    configuration: configuration,
                    state: $editorState,
                    coordinators: [findPanelFix]
                )
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

    private var textBinding: Binding<String> {
        Binding(
            get: { file.text },
            set: { newValue in
                guard newValue != file.text else { return }
                file.text = newValue
                file.markDirty()
            }
        )
    }

    /// Derived per render, so appearance and font changes restyle the
    /// editor without any explicit invalidation.
    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: EditorThemes.theme(dark: colorScheme == .dark),
                font: TerminalFont.current(),
                wrapLines: false
            ),
            // Explicit (zero) insets switch the scroll view off
            // automaticallyAdjustsContentInsets; the automatic mode discards
            // the top inset the editor adds while the find panel is shown,
            // leaving the panel floating over the text instead of pushing
            // it down.
            layout: .init(contentInsets: NSEdgeInsets()),
            peripherals: .init(showMinimap: false, showFoldingRibbon: false)
        )
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

/// Works around two CodeEditSourceEditor find/replace panel bugs:
///
/// 1. The panel is added *behind* the scroll view in the subview order and
///    only raised visually with `layer.zPosition`, which affects drawing but
///    not AppKit hit testing or cursor-update routing — so the panel's
///    controls are unclickable and hovering them keeps the text view's
///    I-beam cursor. Re-sorting the panel to the front of the subview order
///    fixes both (`sortSubviews` reorders without detaching, so the panel's
///    constraints survive).
/// 2. Its container has `clipsToBounds = false`, so the show/hide animation
///    slides the panel in from above the editor, across the tab strip.
///    Clipping the container makes it emerge from the editor's top edge.
///    (Not noticeable in CodeEdit, where an opaque toolbar covers that area.)
final class FindPanelClickFixCoordinator: TextViewCoordinator {
    func prepareCoordinator(controller: TextViewController) {
        // The find panel is created in loadView, after coordinators run.
        DispatchQueue.main.async { [weak controller] in
            guard let view = controller?.viewIfLoaded else { return }
            Self.fixFindPanel(in: view)
        }
    }

    private static func fixFindPanel(in root: NSView) {
        for subview in root.subviews {
            if String(describing: type(of: subview)) == "FindPanelHostingView" {
                root.clipsToBounds = true
                root.sortSubviews({ first, _, _ in
                    String(describing: type(of: first)) == "FindPanelHostingView"
                        ? .orderedDescending : .orderedAscending
                }, context: nil)
                return
            }
            fixFindPanel(in: subview)
        }
    }
}

/// Editor colors matching the app's GitHub Light / GitHub Dark theme
/// (`Theme.background` is the same hex, so the editor blends into the
/// window). Static colors, rebuilt when the color scheme flips.
private enum EditorThemes {
    static func theme(dark: Bool) -> EditorTheme {
        dark
            ? EditorTheme(
                text: attr(0xe6edf3),
                insertionPoint: color(0x58a6ff),
                invisibles: attr(0x484f58),
                background: color(0x0d1117),
                lineHighlight: color(0x161b22),
                selection: color(0x1f6feb, alpha: 0.35),
                keywords: attr(0xff7b72),
                commands: attr(0xd2a8ff),
                types: attr(0xffa657),
                attributes: attr(0x79c0ff),
                variables: attr(0xe6edf3),
                values: attr(0x79c0ff),
                numbers: attr(0x79c0ff),
                strings: attr(0xa5d6ff),
                characters: attr(0xa5d6ff),
                comments: attr(0x8b949e)
            )
            : EditorTheme(
                text: attr(0x1f2328),
                insertionPoint: color(0x0969da),
                invisibles: attr(0xafb8c1),
                background: color(0xffffff),
                lineHighlight: color(0xf6f8fa),
                selection: color(0x54aeff, alpha: 0.4),
                keywords: attr(0xcf222e),
                commands: attr(0x8250df),
                types: attr(0x953800),
                attributes: attr(0x0550ae),
                variables: attr(0x1f2328),
                values: attr(0x0550ae),
                numbers: attr(0x0550ae),
                strings: attr(0x0a3069),
                characters: attr(0x0a3069),
                comments: attr(0x6e7781)
            )
    }

    private static func attr(_ hex: Int) -> EditorTheme.Attribute {
        EditorTheme.Attribute(color: color(hex))
    }

    private static func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: alpha
        )
    }
}
