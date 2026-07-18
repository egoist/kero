//
//  FileViewerView.swift
//  mitty
//

import AppKit
import Combine
import Highlightr
import SwiftUI

/// A file opened as a tab in a project. Text files load into a Highlightr
/// `CodeAttributedString` so syntax highlighting tracks edits; the storage
/// lives here (not in the view) so edits survive tab switches.
@MainActor
final class FileTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()
    let path: String

    enum Content {
        case text(CodeAttributedString)
        case image(NSImage)
        case unavailable(String)
    }

    let content: Content
    @Published private(set) var isDirty = false
    @Published var saveError: String?

    private static let maxTextBytes = 5 << 20
    /// Above this size the JS highlighter gets too slow; edit as plain text.
    private static let maxHighlightBytes = 512 << 10
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "icns",
    ]

    init(path: String) {
        self.path = path
        content = Self.load(path: path)
        applyTheme()
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    /// Matches the editor colors to the app appearance and terminal font.
    /// Reassigning the theme makes `CodeAttributedString` re-highlight.
    func applyTheme() {
        guard case .text(let storage) = content else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Highlightr's CSS parser only understands simple class-list
        // selectors; the modern "github"/"github-dark" themes use compound
        // selectors and lose most token colors. These two parse fully.
        storage.highlightr.setTheme(to: isDark ? "atom-one-dark" : "github-gist")
        guard let theme = storage.highlightr.theme else { return }
        theme.setCodeFont(TerminalFont.current())
        storage.highlightr.theme = theme
        if storage.language == nil {
            // No highlighter pass will attribute plain text; do it directly.
            storage.setAttributes(
                [.font: theme.codeFont as Any, .foregroundColor: NSColor.labelColor],
                range: NSRange(location: 0, length: storage.length)
            )
        }
    }

    func markDirty() {
        if !isDirty {
            isDirty = true
        }
    }

    func save() {
        guard case .text(let storage) = content, isDirty else { return }
        do {
            try storage.string.write(toFile: path, atomically: true, encoding: .utf8)
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func load(path: String) -> Content {
        let url = URL(fileURLWithPath: path)
        if imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            return .image(image)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unavailable("Could not read file")
        }
        guard data.count <= maxTextBytes else {
            return .unavailable("File is too large to open")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unavailable("Binary file")
        }
        let storage = CodeAttributedString()
        if data.count <= maxHighlightBytes {
            storage.language = language(for: url)
        }
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return .text(storage)
    }

    /// highlight.js language name for a file, nil for plain text.
    private static func language(for url: URL) -> String? {
        switch url.lastPathComponent.lowercased() {
        case "makefile": return "makefile"
        case "dockerfile": return "dockerfile"
        default: break
        }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "m", "mm": return "objectivec"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "cs": return "csharp"
        case "php": return "php"
        case "pl": return "perl"
        case "lua": return "lua"
        case "sql": return "sql"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "conf": return "ini"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh", "fish": return "bash"
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "diff", "patch": return "diff"
        case "vim": return "vim"
        default: return nil
        }
    }
}

/// Content of a file tab: an editable, syntax-highlighted text view, an
/// image preview, or a placeholder for anything binary or oversized.
struct FileViewerView: View {
    @ObservedObject var file: FileTab

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch file.content {
            case .text(let storage):
                VStack(spacing: 0) {
                    if let error = file.saveError {
                        saveErrorBar(error)
                    }
                    CodeEditorView(storage: storage, onEdit: { file.markDirty() })
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
        .onChange(of: colorScheme) { file.applyTheme() }
        .onChange(of: settings.fontFamily) { file.applyTheme() }
        .onChange(of: settings.fontSize) { file.applyTheme() }
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

/// Editable, non-wrapping NSTextView backed by the tab's highlighting
/// text storage.
private struct CodeEditorView: NSViewRepresentable {
    let storage: CodeAttributedString
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(storage: storage, onEdit: onEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.cursor
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = TerminalFont.current()
        textView.typingAttributes = [
            .font: TerminalFont.current(),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    /// The storage outlives this view (it belongs to the tab), so detach
    /// the layout manager or the storage would keep dead views alive and
    /// highlight into them.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let textView = scroll.documentView as? NSTextView,
           let layoutManager = textView.layoutManager {
            coordinator.storage.removeLayoutManager(layoutManager)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let storage: CodeAttributedString
        let onEdit: () -> Void

        init(storage: CodeAttributedString, onEdit: @escaping () -> Void) {
            self.storage = storage
            self.onEdit = onEdit
        }

        func textDidChange(_ notification: Notification) {
            onEdit()
        }
    }
}
