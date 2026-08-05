//
//  DiffViewerView.swift
//  kero
//

import AppKit
import Combine
import Foundation
import PierreDiffsSwift
import SwiftUI

/// Mutable pipe storage shared by the two dedicated readers in
/// `DiffTab.runGitData`. Each instance is written by exactly one reader.
private nonisolated final class DiffPipeData: @unchecked Sendable {
    var value = Data()
}

/// Lightweight UI state that should follow Kero across launches without
/// becoming a user-facing TOML setting.
@MainActor
private final class DiffViewPreferences: ObservableObject {
    static let shared = DiffViewPreferences()

    private static let layoutKey = "diffView.layout"
    private static let modeKey = "diffView.mode"

    @Published var diffStyle: DiffStyle {
        didSet {
            UserDefaults.standard.set(diffStyle.rawValue, forKey: Self.layoutKey)
        }
    }

    @Published var prefersEditing: Bool {
        didSet {
            UserDefaults.standard.set(
                prefersEditing ? "edit" : "review",
                forKey: Self.modeKey
            )
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: Self.layoutKey),
           let style = DiffStyle(rawValue: rawValue) {
            diffStyle = style
        } else {
            diffStyle = .unified
        }
        prefersEditing = defaults.string(forKey: Self.modeKey) == "edit"
    }
}

/// Observable inputs for a diff tab's web view. Owned by `DiffTab` and also
/// retained by the tab's long-lived hosting view. Its edit callbacks capture
/// the owning `DiffTab` weakly so that view retention cannot leak the tab.
@MainActor
final class DiffWebModel: nonisolated ObservableObject {
    @Published var oldContent = ""
    @Published var newContent = ""
    @Published var fileName = ""
    @Published var fileID = ""
    @Published var canEdit = false
    @Published var overflowMode: OverflowMode = .scroll
    var onFileEditChange: ((String, String) -> Void)?
    var onFileEditComplete: ((String, String) -> Void)?
    /// The WKWebView renders blank until its JS bundle has drawn the diff;
    /// a skeleton covers it until the bridge reports ready.
    @Published var isReady = false
    /// Explicit appearance for the long-lived, separately hosted diff root.
    /// Its NSHostingView is re-parented between SwiftUI containers, so relying
    /// on an implicitly inherited colorScheme can leave WebKit one appearance
    /// behind after macOS changes between light and dark.
    @Published private(set) var usesDarkAppearance = false

    func updateAppearance(_ appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard usesDarkAppearance != isDark else { return }
        usesDarkAppearance = isDark
    }
}

/// A git diff opened as a tab from the git panel. Loads both sides of the
/// change (via `git show` / the worktree) so they survive tab switches;
/// reloads when the view reappears.
@MainActor
final class DiffTab: nonisolated ObservableObject, nonisolated Identifiable {
    nonisolated let id = UUID()

    /// Absolute repository root the diff runs in.
    let repoRoot: String
    /// Repo-relative path, as porcelain reports it.
    let path: String
    /// Diffs HEAD → index instead of index → worktree.
    let staged: Bool
    var untracked: Bool
    /// Historical commit shown by this tab. Nil keeps the existing
    /// index/worktree behavior.
    let commitHash: String?
    /// First parent and name-status metadata used to describe a historical
    /// comparison in the tab strip.
    let commitParentHash: String?
    let commitStatus: Character?
    /// Previous path when the change is a rename/copy; the "before" side
    /// reads from here so renames diff old file → new file like VS Code.
    var origPath: String?

    @Published private(set) var error: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isUnmerged = false
    @Published private(set) var isEditable = false
    @Published private(set) var isDirty = false
    @Published var saveError: String?

    let web = DiffWebModel()

    /// The web view lives on the tab (not in the SwiftUI view) so switching
    /// tabs re-parents the same rendered view instead of booting a fresh
    /// WKWebView — same pattern as `TerminalSession.terminalView`.
    ///
    /// It starts nil so project selection can commit its skeleton before the
    /// selected diff creates WebKit's AppKit hierarchy on the main actor.
    @Published private(set) var webHostView: NSView?

    private nonisolated static let maxBytes = 5 << 20
    private var savedNewContent = ""
    /// Live text emitted by Pierre's editor. Kept out of `DiffWebModel` while
    /// editing so a keystroke does not rebuild the CodeView item that owns the
    /// editor, selection, and undo stack.
    private var editedNewContent = ""
    private var reloadGeneration: UInt = 0

    init(
        repoRoot: String,
        path: String,
        staged: Bool,
        untracked: Bool,
        origPath: String?,
        commitHash: String? = nil,
        commitParentHash: String? = nil,
        commitStatus: Character? = nil
    ) {
        self.repoRoot = repoRoot
        self.path = path
        self.staged = staged
        self.untracked = untracked
        self.origPath = origPath
        self.commitHash = commitHash
        self.commitParentHash = commitParentHash
        self.commitStatus = commitStatus
        web.fileName = name
        web.fileID = path
        web.onFileEditChange = { [weak self] fileID, contents in
            self?.updateEditedContent(fileID: fileID, contents: contents)
        }
        web.onFileEditComplete = { [weak self] fileID, contents in
            self?.completeEditing(fileID: fileID, contents: contents)
        }
        reload()
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var title: String {
        if let commitHash {
            let after = "\(name) (\(commitHash.prefix(7)))"
            guard let commitParentHash else { return after }
            let beforeName = ((origPath ?? path) as NSString).lastPathComponent
            let before = "\(beforeName) (\(commitParentHash.prefix(7)))"
            switch commitStatus {
            case "A": return after
            case "D": return before
            default: return "\(before) ↔ \(after)"
            }
        }
        return staged
            ? String(localized: "\(name) (Staged)", comment: "Tab title for the staged diff of a file.")
            : name
    }

    func reload() {
        // Keep the editor's document and undo history stable until the user
        // leaves edit mode, and never replace an unsaved buffer from disk.
        guard !isEditing, !isDirty else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        error = nil
        let root = repoRoot
        let path = path
        let oldPath = origPath ?? path
        let staged = staged
        let untracked = untracked
        let commitHash = commitHash

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var failureVar: String?
                let unmerged = commitHash == nil && !staged
                    && Self.isUnmerged(path: path, in: root)
                let old: String
                let new: String
                if let commitHash {
                    old = Self.firstGitContent(
                        ["\(commitHash)^:\(oldPath)"], in: root, error: &failureVar
                    )
                    new = Self.firstGitContent(
                        ["\(commitHash):\(path)"], in: root, error: &failureVar
                    )
                } else if staged {
                    old = Self.firstGitContent(
                        ["HEAD:\(oldPath)"], in: root, error: &failureVar
                    )
                    new = Self.firstGitContent(
                        [":\(path)"], in: root, error: &failureVar
                    )
                } else {
                    if untracked {
                        old = ""
                    } else {
                        // An unmerged index has no stage-0 `:path`. Prefer our
                        // side, then the merge base, so conflict rows show a
                        // meaningful before-side instead of the whole file as new.
                        old = Self.firstGitContent(
                            [":\(oldPath)", ":2:\(oldPath)", ":1:\(oldPath)", "HEAD:\(oldPath)"],
                            in: root,
                            error: &failureVar
                        )
                    }
                    new = Self.readWorktreeFile(root: root, path: path, error: &failureVar)
                }
                let editable = commitHash == nil && !staged
                    && Self.isEditableWorktreeFile(root: root, path: path)
                return (
                    old: old,
                    new: new,
                    failure: failureVar,
                    unmerged: unmerged,
                    editable: editable
                )
            }.value
            guard let self, self.reloadGeneration == generation else { return }
            self.isLoading = false
            self.error = result.failure
            self.isUnmerged = result.unmerged
            self.isEditable = result.editable && result.failure == nil
            self.web.canEdit = self.isEditable
            self.web.oldContent = result.old
            self.web.newContent = result.new
            self.savedNewContent = result.new
            self.editedNewContent = result.new
            self.isDirty = false
            self.saveError = nil
        }
    }

    /// Refreshes a live diff when navigation brings it back on screen.
    /// Historical blobs are immutable and already loaded by `init`; rerunning
    /// four Git processes and republishing both files on every project switch
    /// only makes WebKit render the same diff again. An initial live load also
    /// stays in flight rather than being duplicated by the view's first mount.
    func refreshWhenSelected() {
        guard commitHash == nil, !isLoading else { return }
        reload()
    }

    /// WebKit views are main-actor objects, but their creation does not need to
    /// be part of the project-selection transaction. Yielding lets SwiftUI
    /// display the existing skeleton first and avoids materializing every
    /// hidden diff in a project at once.
    func materializeWebHostView() async {
        guard webHostView == nil else { return }
        await Task.yield()
        guard !Task.isCancelled, webHostView == nil else { return }
        web.updateAppearance(NSApp.effectiveAppearance)
        webHostView = DiffWebHostingView(model: web)
    }

    /// Accepts the updated side emitted by Pierre's editor. The web view owns
    /// the live document; this mirrored value drives dirty state and saving.
    func updateEditedContent(fileID: String, contents: String) {
        guard isEditable, fileID == path else { return }
        editedNewContent = contents
        isDirty = contents != savedNewContent
        if isDirty {
            // A reload already in flight must not win after the first edit.
            reloadGeneration &+= 1
        }
    }

    /// Once Pierre has torn down its editor, publish the final buffer so the
    /// read-only diff renders the text the user just reviewed and edited.
    func completeEditing(fileID: String, contents: String) {
        updateEditedContent(fileID: fileID, contents: contents)
        guard isEditable, fileID == path else { return }
        web.newContent = contents
    }

    func setDiffStyle(_ style: DiffStyle) {
        DiffViewPreferences.shared.diffStyle = style
    }

    func setEditing(_ isEditing: Bool) {
        guard isEditable else { return }
        DiffViewPreferences.shared.prefersEditing = isEditing
    }

    private var isEditing: Bool {
        isEditable && DiffViewPreferences.shared.prefersEditing
    }

    func save() {
        guard isEditable, isDirty else { return }
        let fileURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(path)
        do {
            try editedNewContent.write(to: fileURL, atomically: true, encoding: .utf8)
            savedNewContent = editedNewContent
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    private nonisolated enum GitContent {
        case missing
        case content(String)
        case binary
        case tooLarge
    }

    private nonisolated static func firstGitContent(
        _ specs: [String], in root: String, error: inout String?
    ) -> String {
        for spec in specs {
            switch gitContent(spec, in: root) {
            case .missing:
                continue
            case .content(let content):
                return content
            case .binary:
                error = String(localized: "Binary file")
                return ""
            case .tooLarge:
                error = String(localized: "File is too large to diff")
                return ""
            }
        }
        return ""
    }

    private nonisolated static func gitContent(_ spec: String, in root: String) -> GitContent {
        let size = GitStatusModel.runGit(["cat-file", "-s", spec], in: root)
        guard size.status == 0 else { return .missing }
        let byteCount = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard byteCount <= maxBytes else { return .tooLarge }
        let run = runGitData(["cat-file", "blob", spec], in: root)
        guard run.status == 0 else { return .missing }
        guard run.stdout.count <= maxBytes else { return .tooLarge }
        guard !run.stdout.contains(0),
              let content = String(data: run.stdout, encoding: .utf8)
        else {
            return .binary
        }
        return .content(content)
    }

    /// GitStatusModel's general runner intentionally exposes decoded text.
    /// Diff blobs need their original bytes so invalid UTF-8 and embedded NULs
    /// cannot be mistaken for an empty text file.
    private nonisolated static func runGitData(
        _ args: [String], in root: String
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }

        let outData = DiffPipeData()
        let errData = DiffPipeData()
        let captureLimit = maxBytes + 1
        let readers = DispatchGroup()
        // Pipe EOF is part of this synchronous Git operation. Matching the
        // caller avoids a user-initiated diff load waiting on utility readers.
        let readerQualityOfService = Thread.current.qualityOfService
        readers.enter()
        let stdoutReader = Thread {
            // Drain the pipe so Git cannot deadlock, but retain at most one
            // byte beyond the limit. The index may change between cat-file's
            // size check and this read while an agent is working.
            while true {
                let chunk: Data
                do {
                    guard let next = try stdout.fileHandleForReading.read(upToCount: 64 * 1024),
                          !next.isEmpty else { break }
                    chunk = next
                } catch {
                    break
                }
                let remaining = captureLimit - outData.value.count
                if remaining > 0 {
                    outData.value.append(chunk.prefix(remaining))
                }
            }
            readers.leave()
        }
        stdoutReader.qualityOfService = readerQualityOfService
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            errData.value = stderr.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        stderrReader.qualityOfService = readerQualityOfService
        stderrReader.start()
        process.waitUntilExit()
        readers.wait()
        return (
            process.terminationStatus,
            outData.value,
            String(data: errData.value, encoding: .utf8) ?? ""
        )
    }

    private nonisolated static func isUnmerged(path: String, in root: String) -> Bool {
        let run = GitStatusModel.runGit(
            ["--literal-pathspecs", "ls-files", "--unmerged", "--", path], in: root
        )
        return run.status == 0 && !run.stdout.isEmpty
    }

    /// Editing is limited to regular worktree files. In particular, writing a
    /// symlink atomically would replace the link itself with a regular file.
    private nonisolated static func isEditableWorktreeFile(root: String, path: String) -> Bool {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { return false }
        return true
    }

    private nonisolated static func readWorktreeFile(
        root: String, path: String, error: inout String?
    ) -> String {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path)
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            guard destination.utf8.count <= maxBytes else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            return destination
        }
        do {
            // Keep one descriptor for the whole read: replacing the path while
            // an agent writes cannot redirect us to a different, larger file.
            // Seek checks catch growth without ever loading more than maxBytes.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let initialSize = try handle.seekToEnd()
            guard initialSize <= UInt64(maxBytes) else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            try handle.seek(toOffset: 0)

            var data = Data()
            while data.count < maxBytes {
                let remaining = min(64 * 1024, maxBytes - data.count)
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            let finalSize = try handle.seekToEnd()
            guard finalSize <= UInt64(maxBytes) else {
                error = String(localized: "File is too large to diff")
                return ""
            }
            guard !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
            else {
                error = String(localized: "Binary file")
                return ""
            }
            return text
        } catch let readError as CocoaError
            where readError.code == .fileNoSuchFile || readError.code == .fileReadNoSuchFile {
            // Deleted from the worktree: an empty "after" side is the diff.
            return ""
        } catch let fileError {
            error = String(
                localized: "Unable to read file: \(fileError.localizedDescription)",
                comment: "Diff error followed by a system-provided error description."
            )
            return ""
        }
    }
}

/// Font handling for the diff web view, so a diff reads at the same family and
/// size as the terminal and the editor.
///
/// A family the user picked in Settings is installed system-wide and the web
/// view resolves it by name. kero's bundled JetBrains Mono is different:
/// `TerminalFont.registerBundledFonts` registers it for this process only, and
/// the diff renders in a separate WebKit content process that cannot see it —
/// so its faces travel to the web view as embedded font data. Reading and
/// encoding them happens once for the whole app.
private enum DiffFont {
    static func renderOptions(family: String, size: Double) -> PierreDiffRenderOptions {
        let usesBundled = family.isEmpty || family == TerminalFont.bundledFamily
        return PierreDiffRenderOptions(
            font: .bundled(
                familyName: usesBundled ? TerminalFont.bundledFamily : family,
                faces: usesBundled ? bundledFaces : [],
                sizePoints: size
            )
        )
    }

    /// All four faces travel, rather than letting the browser synthesize bold
    /// and italic: synthetic faces in a monospace grid do not stay aligned
    /// with the real one.
    private static let bundledFaces: [PierreDiffFontFace] = {
        let variants = [
            ("JetBrainsMono-Regular", "400", "normal"),
            ("JetBrainsMono-Bold", "700", "normal"),
            ("JetBrainsMono-Italic", "400", "italic"),
            ("JetBrainsMono-BoldItalic", "700", "italic"),
        ]
        return variants.compactMap { resource, weight, style in
            PierreDiffFontFace.load(
                family: TerminalFont.bundledFamily,
                resource: resource,
                extension: "ttf",
                weight: weight,
                style: style
            )
        }
    }()
}

/// Root of the tab-owned hosting view: keeps the diff web view (and its
/// WKWebView) alive for the tab's lifetime, re-rendering when the model's
/// inputs change.
///
/// A tab still shows exactly one file. It goes through the multi-file surface
/// holding that single file because that is the virtualized path: rows are
/// rendered only while on screen and syntax highlighting runs in a worker, so
/// opening or scrolling a large diff never stalls the main thread. The
/// single-file view renders every row up front and highlights them inline.
private struct DiffWebRoot: View {
    @ObservedObject var model: DiffWebModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var preferences = DiffViewPreferences.shared

    var body: some View {
        PierreMultiDiffView(
            files: [
                PierreDiffFile(
                    id: model.fileID,
                    name: model.fileName,
                    oldContents: model.oldContent,
                    newContents: model.newContent,
                    isEditable: model.canEdit && preferences.prefersEditing
                )
            ],
            diffStyle: $preferences.diffStyle,
            overflowMode: $model.overflowMode,
            renderOptions: DiffFont.renderOptions(
                family: settings.fontFamily, size: settings.fontSize
            ),
            onFileEditChange: { fileID, contents in
                model.onFileEditChange?(fileID, contents)
            },
            onFileEditComplete: { fileID, contents in
                model.onFileEditComplete?(fileID, contents)
            },
            onReady: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isReady = true
                }
            }
        )
        // Pierre derives its JavaScript theme from this environment value.
        // Make it follow the host view's effective AppKit appearance instead
        // of a colorScheme captured while the detached host was constructed.
        .environment(
            \.colorScheme,
            model.usesDarkAppearance ? ColorScheme.dark : ColorScheme.light
        )
    }
}

/// Bridges the actual AppKit appearance into the detached SwiftUI diff root.
/// AppKit sends this callback only after the view's effective appearance has
/// changed, avoiding the old/new ordering race of a global system notification.
private final class DiffWebHostingView: NSHostingView<DiffWebRoot> {
    private let model: DiffWebModel

    init(model: DiffWebModel) {
        self.model = model
        super.init(rootView: DiffWebRoot(model: model))
    }

    @available(*, unavailable)
    required init(rootView: DiffWebRoot) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model.updateAppearance(effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        model.updateAppearance(effectiveAppearance)
    }
}

/// Re-parents a tab's long-lived web host view into the current tab area;
/// AppKit detaches it from any previous container automatically.
private struct DiffWebHostView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Renders a diff tab with PierreDiffsSwift: syntax-highlighted unified or
/// split view with word-level change highlighting.
struct DiffViewerView: View {
    @ObservedObject var diff: DiffTab
    @ObservedObject private var themeChanges = Theme.changes
    @ObservedObject private var web: DiffWebModel
    @ObservedObject private var preferences = DiffViewPreferences.shared
    /// The view stays mounted while other tabs are selected (see
    /// ContentView); this flags when it is the frontmost tab so content
    /// refreshes on each re-visit, not just on first mount.
    let isSelected: Bool

    init(diff: DiffTab, isSelected: Bool = true) {
        _diff = ObservedObject(wrappedValue: diff)
        _web = ObservedObject(wrappedValue: diff.web)
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            if diff.isUnmerged {
                conflictBanner
            }
            if let saveError = diff.saveError {
                saveErrorBar(saveError)
            }
            Group {
                if let error = diff.error {
                    placeholder(icon: "exclamationmark.triangle", text: error)
                } else if web.oldContent == web.newContent {
                    if diff.isLoading {
                        initialLoadingSkeleton
                    } else if diff.isUnmerged {
                        placeholder(
                            icon: "arrow.triangle.merge",
                            text: String(localized: "Conflict is still unresolved")
                        )
                    } else {
                        placeholder(icon: "checkmark.circle", text: String(localized: "No changes"))
                    }
                } else {
                    VStack(spacing: 0) {
                        controlBar
                        if let webHostView = diff.webHostView {
                            DiffWebHostView(view: webHostView)
                                // Cover (never hide) the webview while it boots:
                                // making it invisible lets WebKit throttle rendering
                                // and the initial diff render can be dropped entirely.
                                .overlay {
                                    if !web.isReady {
                                        DiffSkeletonView()
                                            .background(Color(nsColor: Theme.background))
                                            .transition(.opacity)
                                    }
                                }
                        } else {
                            DiffSkeletonView()
                                .task(id: isSelected) {
                                    guard isSelected else { return }
                                    await diff.materializeWebHostView()
                                }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if isSelected {
                diff.refreshWhenSelected()
            }
        }
        .onChange(of: isSelected) {
            if isSelected {
                diff.refreshWhenSelected()
            }
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.merge")
            Text("Unresolved merge conflict")
                .fontWeight(.medium)
            Spacer(minLength: 0)
            Text("Resolve before committing")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.orange.opacity(0.22))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var controlBar: some View {
        DiffControlsBar(
            diffStyle: Binding(
                get: { preferences.diffStyle },
                set: { diff.setDiffStyle($0) }
            ),
            isEditing: Binding(
                get: { diff.isEditable && preferences.prefersEditing },
                set: { diff.setEditing($0) }
            ),
            canEdit: diff.isEditable
        )
        .frame(height: DiffViewerLayout.controlsHeight)
    }

    /// The WebKit skeleton later sits below the real controls. Reserve that
    /// exact toolbar row during the file load too, so the code-shaped lines do
    /// not jump down when the diff contents become available.
    private var initialLoadingSkeleton: some View {
        VStack(spacing: 0) {
            DiffControlsSkeletonBar(
                showsModePlaceholder: diff.commitHash == nil && !diff.staged
            )
            .frame(height: DiffViewerLayout.controlsHeight)
            DiffSkeletonView()
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private enum DiffViewerLayout {
    static let controlsHeight: CGFloat = 37
}

/// Native controls for the materially changed diff toolbar. The surrounding
/// diff view is legacy SwiftUI, but new interaction stays in AppKit.
private struct DiffControlsBar: NSViewRepresentable {
    @Binding var diffStyle: DiffStyle
    @Binding var isEditing: Bool
    let canEdit: Bool

    func makeNSView(context: Context) -> DiffControlsNSView {
        DiffControlsNSView()
    }

    func updateNSView(_ view: DiffControlsNSView, context: Context) {
        view.update(
            diffStyle: diffStyle,
            isEditing: isEditing,
            canEdit: canEdit,
            onDiffStyleChange: { diffStyle = $0 },
            onEditingChange: { isEditing = $0 }
        )
    }
}

/// Matches the native controls row while the diff metadata is still loading.
/// Keeping this in AppKit gives the placeholder the same sizing and divider
/// behavior as the toolbar that replaces it.
private struct DiffControlsSkeletonBar: NSViewRepresentable {
    let showsModePlaceholder: Bool

    func makeNSView(context: Context) -> DiffControlsSkeletonNSView {
        DiffControlsSkeletonNSView()
    }

    func updateNSView(_ view: DiffControlsSkeletonNSView, context: Context) {
        view.update(showsModePlaceholder: showsModePlaceholder)
    }
}

private final class DiffControlsSkeletonNSView: NSView {
    private let modePlaceholder = NSView()
    private let layoutPlaceholder = NSView()
    private let divider = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)

        for placeholder in [modePlaceholder, layoutPlaceholder] {
            placeholder.wantsLayer = true
            placeholder.layer?.cornerRadius = 5
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            addSubview(placeholder)
        }

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            layoutPlaceholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutPlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            layoutPlaceholder.widthAnchor.constraint(equalToConstant: 111),
            layoutPlaceholder.heightAnchor.constraint(equalToConstant: 20),
            modePlaceholder.trailingAnchor.constraint(
                equalTo: layoutPlaceholder.leadingAnchor, constant: -8
            ),
            modePlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            modePlaceholder.widthAnchor.constraint(equalToConstant: 93),
            modePlaceholder.heightAnchor.constraint(equalToConstant: 20),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(showsModePlaceholder: Bool) {
        updateAppearanceColors()
        modePlaceholder.isHidden = !showsModePlaceholder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            divider.layer?.backgroundColor = Theme.divider.cgColor
            let fill = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            modePlaceholder.layer?.backgroundColor = fill
            layoutPlaceholder.layer?.backgroundColor = fill
        }
    }
}

private final class DiffControlsNSView: NSView {
    private let modeControl = NSSegmentedControl(
        labels: [
            String(localized: "Review", comment: "Read-only mode for a diff."),
            String(localized: "Edit", comment: "Editable mode for a diff."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let layoutControl = NSSegmentedControl(
        labels: [
            String(localized: "Unified", comment: "A single-column diff layout."),
            String(localized: "Split", comment: "A side-by-side diff layout."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let divider = NSView()
    private var onDiffStyleChange: ((DiffStyle) -> Void)?
    private var onEditingChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for control in [modeControl, layoutControl] {
            control.controlSize = .small
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel(String(localized: "Diff Mode"))
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        layoutControl.setAccessibilityLabel(String(localized: "Diff Layout"))

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            layoutControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeControl.trailingAnchor.constraint(equalTo: layoutControl.leadingAnchor, constant: -8),
            modeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        diffStyle: DiffStyle,
        isEditing: Bool,
        canEdit: Bool,
        onDiffStyleChange: @escaping (DiffStyle) -> Void,
        onEditingChange: @escaping (Bool) -> Void
    ) {
        self.onDiffStyleChange = onDiffStyleChange
        self.onEditingChange = onEditingChange
        updateAppearanceColors()

        layoutControl.selectedSegment = diffStyle == .split ? 1 : 0
        modeControl.isHidden = !canEdit
        modeControl.setEnabled(canEdit, forSegment: 1)
        modeControl.selectedSegment = canEdit && isEditing ? 1 : 0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
        modeControl.needsDisplay = true
        layoutControl.needsDisplay = true
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            divider.layer?.backgroundColor = Theme.divider.cgColor
        }
    }

    @objc private func modeChanged() {
        onEditingChange?(modeControl.selectedSegment == 1)
    }

    @objc private func layoutChanged() {
        onDiffStyleChange?(layoutControl.selectedSegment == 1 ? .split : .unified)
    }
}

/// Code-shaped gray bars shown while the diff web view boots, so opening
/// a diff never flashes an empty pane.
private struct DiffSkeletonView: View {
    /// (indent level, width fraction) per line, repeated to fill the pane.
    private static let pattern: [(indent: CGFloat, width: CGFloat)] = [
        (0, 0.42), (1, 0.62), (1, 0.30), (1, 0.55),
        (2, 0.38), (2, 0.50), (1, 0.24), (0, 0.16),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<24, id: \.self) { index in
                    let line = Self.pattern[index % Self.pattern.count]
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: geo.size.width * line.width * 0.55, height: 9)
                        .padding(.leading, line.indent * 18)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}
