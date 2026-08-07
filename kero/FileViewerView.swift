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

/// Content of a file tab, hosted in AppKit: the source editor, the rendered
/// markdown preview, an image, or a placeholder for anything binary or
/// oversized. SwiftUI is only the mount point — `FileViewerContainerView` owns
/// the views and the switching between them.
struct FileViewerView: NSViewRepresentable {
    @ObservedObject var file: FileTab
    /// Whether this file's pane is the focused one in its tab.
    var isFocused: Bool = true
    /// Called when the editor takes focus itself (e.g. a click), so the
    /// model's focused pane can follow.
    var onFocused: () -> Void = {}
    /// Splits this pane on the given edge — wired to the context-menu items.
    var onSplit: (PaneDropEdge) -> Void = { _ in }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var markdownPreferences = MarkdownViewPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> FileViewerContainerView {
        let view = FileViewerContainerView(file: file)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: FileViewerContainerView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: FileViewerContainerView) {
        view.update(
            font: TerminalFont.current(),
            palette: .theme(dark: colorScheme == .dark),
            wrapLines: settings.wrapLines,
            isFocused: isFocused,
            showsSource: markdownPreferences.showsSource,
            onFocused: onFocused,
            onSplit: onSplit
        )
    }

    /// Take exactly the space SwiftUI offers. Without this, SwiftUI sizes the
    /// pane from the content's `fittingSize`, which a text view derives from the
    /// entire document — enormous for a large file, and degenerate for an empty
    /// one. Because the main window tracks its content's ideal size, that runaway
    /// measurement drives the window size and drops it into an unbounded layout
    /// loop (a hard crash: "more Layout Window passes than there are views").
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: FileViewerContainerView, context: Context
    ) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }
}

/// The AppKit body of a file tab. Holds whichever content view the tab's state
/// calls for, plus the markdown mode chip and the save-error bar, and swaps
/// content in place as the file reloads or the reader toggles modes.
@MainActor
final class FileViewerContainerView: NSView {
    private let file: FileTab

    private var editor: SourceEditorController?
    private var preview: MarkdownPreviewView?
    /// The currently mounted content view, whichever kind it is.
    private var contentView: NSView?
    private var contentKind: ContentKind?
    private let chip = MarkdownModeChipView()
    private let errorBar = FileSaveErrorBar()

    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var palette = EditorPalette.theme(dark: true)
    private var wrapLines = false
    private var isFocused = false
    private var showsSource = false
    private var onFocused: () -> Void = {}
    private var onSplit: (PaneDropEdge) -> Void = { _ in }

    /// Last reload the mounted content was built from. A bump means the bytes
    /// on disk changed under a clean tab, so the content has to be rebuilt.
    private var mountedRevision: UInt = 0
    /// Path the mounted content was built for, so a rename can re-resolve the
    /// preview's relative links and images against the new directory.
    private var mountedPath: String?
    private var errorBarHeight: NSLayoutConstraint?

    /// Which view the tab's current state calls for.
    private enum ContentKind: Equatable {
        case source
        case preview
        case image
        case unavailable(String)
    }

    init(file: FileTab) {
        self.file = file
        super.init(frame: .zero)

        errorBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorBar)
        let height = errorBar.heightAnchor.constraint(equalToConstant: 0)
        errorBarHeight = height
        NSLayoutConstraint.activate([
            errorBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            errorBar.topAnchor.constraint(equalTo: topAnchor),
            height,
        ])

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.isHidden = true
        chip.onToggle = { [weak self] in
            // Clicking the chip in an unfocused split has to move the model's
            // focus too, or the pane swaps modes while ⌘F and the Find menu
            // keep acting on whichever pane was focused before.
            self?.onFocused()
            MarkdownViewPreferences.shared.showsSource.toggle()
        }
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -MarkdownModeChipView.trailingInset
            ),
            chip.topAnchor.constraint(
                equalTo: errorBar.bottomAnchor,
                constant: MarkdownModeChipView.topInset
            ),
        ])

        // The selected file view stays mounted while kero is inactive, so
        // returning from an external editor does not trigger a fresh mount.
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reloadFromDisk),
                name: name,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        file.reloadFromDiskIfClean()
    }

    @objc private func reloadFromDisk() {
        file.reloadFromDiskIfClean()
    }

    func update(
        font: NSFont,
        palette: EditorPalette,
        wrapLines: Bool,
        isFocused: Bool,
        showsSource: Bool,
        onFocused: @escaping () -> Void,
        onSplit: @escaping (PaneDropEdge) -> Void
    ) {
        self.font = font
        self.palette = palette
        self.wrapLines = wrapLines
        self.isFocused = isFocused
        self.showsSource = showsSource
        self.onFocused = onFocused
        self.onSplit = onSplit

        errorBar.message = file.saveError
        errorBarHeight?.constant = file.saveError == nil ? 0 : FileSaveErrorBar.height

        // Markdown is the only file type with two ways to read it, so the chip
        // exists only there.
        let isMarkdown = Self.isMarkdown(file.path)
        chip.isHidden = !isMarkdown || !isTextContent
        chip.update(showsSource: showsSource)

        installContentIfNeeded()
        // A rename re-points the tab without touching the bytes, so nothing
        // above notices — but the preview resolves `./img.png` against the
        // file's directory, which just moved.
        if mountedPath != file.path {
            mountedPath = file.path
            preview?.reloadForPathChange()
        }
        editor?.update(
            font: font,
            palette: palette,
            wrapLines: wrapLines,
            isFocused: isFocused,
            onFocused: onFocused,
            onSplit: onSplit
        )
        preview?.onSplit = onSplit
    }

    private var isTextContent: Bool {
        if case .text = file.content { return true }
        return false
    }

    /// Rendered by default, source on request — and always source for anything
    /// that is not markdown.
    private var desiredKind: ContentKind {
        switch file.content {
        case .text:
            Self.isMarkdown(file.path) && !showsSource ? .preview : .source
        case .image:
            .image
        case .unavailable(let reason):
            .unavailable(reason)
        }
    }

    private func installContentIfNeeded() {
        let kind = desiredKind
        let revision = file.reloadRevision
        guard kind != contentKind || revision != mountedRevision else { return }
        let isModeSwitch = contentKind != nil && revision == mountedRevision
        // Only new bytes on disk make the cached views stale. Toggling modes
        // keeps them: rebuilding the editor would hand it a fresh STTextView,
        // and with it a fresh undo manager, so a round trip through the preview
        // would silently throw away everything ⌘Z could have undone.
        if revision != mountedRevision {
            editor = nil
            preview = nil
        }
        contentKind = kind
        mountedRevision = revision

        contentView?.removeFromSuperview()
        contentView = nil

        let view: NSView
        switch kind {
        case .source:
            let controller = editor ?? SourceEditorController(
                file: file,
                font: font,
                palette: palette,
                wrapLines: wrapLines,
                isFocused: isFocused,
                onFocused: onFocused,
                onSplit: onSplit
            )
            editor = controller
            // Find acts on whichever view is mounted, and a reused controller
            // set this only when it was first built.
            file.editorView = controller.scrollView
            view = controller.scrollView
        case .preview:
            let markdown: MarkdownPreviewView
            if let existing = preview {
                markdown = existing
            } else {
                markdown = MarkdownPreviewView(file: file)
                markdown.onFocused = onFocused
                markdown.onSplit = onSplit
                preview = markdown
            }
            // Edits made in the source since this view last drew. The image
            // cache survives, so toggling back does not refetch remote images,
            // and the scroll position is kept by the re-render.
            markdown.refresh()
            file.editorView = markdown
            view = markdown
        case .image:
            view = Self.imageView(for: file, palette: palette)
        case .unavailable(let reason):
            view = Self.placeholderView(path: file.path, reason: reason, palette: palette)
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: chip)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: errorBar.bottomAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        contentView = view

        // Toggling modes should leave the keyboard where the reader is looking;
        // a plain remount (a disk reload) must not steal focus from elsewhere.
        if isModeSwitch, isFocused {
            switch kind {
            case .preview: preview?.takeFocus()
            case .source: editor?.takeFocus()
            case .image, .unavailable: break
            }
        }
    }

    /// v1 renders `.md` only. Other markdown spellings still open as source.
    static func isMarkdown(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "md"
    }

    private static func imageView(for file: FileTab, palette: EditorPalette) -> NSView {
        guard case .image(let image) = file.content else { return NSView() }
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.frame = CGRect(origin: .zero, size: image.size)

        let scrollView = NSScrollView()
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = palette.background
        return scrollView
    }

    private static func placeholderView(
        path: String,
        reason: String,
        palette: EditorPalette
    ) -> NSView {
        let container = NSView()
        let icon = NSImageView()
        icon.image = MaterialFileIcon.image(forPath: path)
        icon.alphaValue = 0.72
        let label = NSTextField(labelWithString: reason)
        label.font = .systemFont(ofSize: 11)
        label.textColor = palette.gutterText

        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            icon.bottomAnchor.constraint(equalTo: container.centerYAnchor, constant: -4),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
        ])
        return container
    }
}

/// The strip above a file's content that reports a failed save.
private final class FileSaveErrorBar: NSView {
    static let height: CGFloat = 22

    var message: String? {
        didSet {
            isHidden = message == nil
            guard let message else { return }
            label.stringValue = String(localized: "Could not save: \(message)")
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        let warning = NSColor(red: 0.82, green: 0.60, blue: 0.13, alpha: 1)
        icon.contentTintColor = warning
        label.font = .systemFont(ofSize: 11)
        label.textColor = warning
        label.lineBreakMode = .byTruncatingTail

        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
