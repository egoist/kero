//
//  CommandPaletteView.swift
//  kero
//

import AppKit
import Combine
import FuzzyMatch
import SwiftUI

/// Groups palette rows under a header — built-in actions, project files, and
/// open sessions.
enum PaletteSection: Hashable {
    case command
    case file
    case session

    var title: String {
        switch self {
        case .command: return String(localized: "Commands", comment: "Command palette section title.")
        case .file: return String(localized: "Files", comment: "Command palette section title.")
        case .session: return String(localized: "Sessions", comment: "Command palette section title.")
        }
    }
}

/// One selectable entry in the ⌘P palette: a built-in action, project file, or
/// jump to an open terminal session.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// Secondary text shown after the title — a file or session directory.
    var subtitle: String? = nil
    var shortcut: String? = nil
    var section: PaletteSection = .command
    /// Text the fuzzy filter matches against; defaults to `title`, widened for
    /// files and sessions to also cover their directories.
    var searchText: String? = nil
    let action: () -> Void

    /// Built-in command copy is a localized resource. Runtime content such as
    /// shell-provided session titles uses the explicitly verbatim initializer.
    init(
        id: String,
        title: LocalizedStringResource,
        systemImage: String,
        subtitle: String? = nil,
        shortcut: String? = nil,
        section: PaletteSection = .command,
        searchText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = String(localized: title)
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.section = section
        self.searchText = searchText
        self.action = action
    }

    init(
        id: String,
        verbatimTitle: String,
        systemImage: String,
        subtitle: String? = nil,
        shortcut: String? = nil,
        section: PaletteSection = .command,
        searchText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = verbatimTitle
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.section = section
        self.searchText = searchText
        self.action = action
    }
}

@MainActor
private final class PalettePointerSelectionController: ObservableObject {
    private(set) var acceptsPointerSelection = false

    func reset() {
        acceptsPointerSelection = false
    }

    func notePointerMoved() {
        acceptsPointerSelection = true
    }
}

/// Centered ⌘P overlay: fuzzy-searchable list of app actions. Arrow keys
/// move the selection, Return runs it, and Escape clears a query before
/// dismissing an already-empty palette.
struct CommandPaletteView: View {
    private struct ScoredProjectFile {
        let file: ProjectFile
        let score: Double
    }

    private struct ProjectFile: Sendable {
        let name: String
        let relativePath: String
        let absolutePath: String

        var parentPath: String? {
            let parent = (relativePath as NSString).deletingLastPathComponent
            return parent.isEmpty ? nil : parent
        }
    }

    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selection = 0
    @State private var projectFiles: [ProjectFile] = []
    @StateObject private var pointerSelectionController = PalettePointerSelectionController()
    @FocusState private var searchFocused: Bool

    /// Smith-Waterman uses fzf/nucleo-style boundary and gap scoring while
    /// remaining fast enough to scan a large project on every keystroke.
    private static let fuzzyMatcher = FuzzyMatcher(config: .smithWaterman)
    private static let maxFileResults = 50

    var body: some View {
        ZStack(alignment: .top) {
            // The palette floats over the terminal surface, whose AppKit cursor
            // rect would otherwise show through as an I-beam across the whole
            // backdrop. Each region of the palette states its own pointer.
            Color.black.opacity(0.15)
                .onTapGesture { dismiss() }
                .pointerStyle(.default)

            panel
                .padding(.top, 110)
        }
        .ignoresSafeArea()
        .background(
            PalettePointerEventMonitor(controller: pointerSelectionController)
        )
        .onExitCommand { handleEscapeFromKeyboard() }
        .onDisappear { manager.restoreFocusAfterCommandPalette() }
        .task(id: fileIndexRoot) {
            projectFiles = []
            guard let root = fileIndexRoot else { return }
            let indexingTask = Task.detached(priority: .userInitiated) {
                Self.loadProjectFiles(in: root)
            }
            let files = await withTaskCancellationHandler {
                await indexingTask.value
            } onCancel: {
                indexingTask.cancel()
            }
            guard !Task.isCancelled, root == fileIndexRoot else { return }
            projectFiles = files
        }
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        var items: [PaletteCommand] = [
            PaletteCommand(id: "new-session", title: "New Session", systemImage: "terminal", shortcut: "⌘T") {
                manager.newSession()
            },
            PaletteCommand(id: "new-browser-tab", title: "New Browser Tab", systemImage: "globe") {
                manager.newBrowserTab()
            },
            PaletteCommand(id: "new-browser-pane", title: "New Browser Pane", systemImage: "globe") {
                manager.newBrowserPane()
            },
            PaletteCommand(id: "clear-terminal", title: "Clear Terminal", systemImage: "eraser", shortcut: "⌘K") {
                manager.clearActiveTerminal()
            },
            PaletteCommand(id: "split-right", title: "Split Right", systemImage: "rectangle.split.2x1", shortcut: "⌘D") {
                manager.splitRight()
            },
            PaletteCommand(id: "split-left", title: "Split Left", systemImage: "rectangle.split.2x1") {
                manager.splitLeft()
            },
            PaletteCommand(id: "split-down", title: "Split Down", systemImage: "rectangle.split.1x2", shortcut: "⇧⌘D") {
                manager.splitDown()
            },
            PaletteCommand(id: "split-up", title: "Split Up", systemImage: "rectangle.split.1x2") {
                manager.splitUp()
            },
            PaletteCommand(id: "focus-pane-left", title: "Focus Pane Left", systemImage: "arrow.left", shortcut: "⌥⌘←") {
                manager.focusPaneLeft()
            },
            PaletteCommand(id: "focus-pane-right", title: "Focus Pane Right", systemImage: "arrow.right", shortcut: "⌥⌘→") {
                manager.focusPaneRight()
            },
            PaletteCommand(id: "focus-pane-up", title: "Focus Pane Up", systemImage: "arrow.up", shortcut: "⌥⌘↑") {
                manager.focusPaneUp()
            },
            PaletteCommand(id: "focus-pane-down", title: "Focus Pane Down", systemImage: "arrow.down", shortcut: "⌥⌘↓") {
                manager.focusPaneDown()
            },
            PaletteCommand(id: "focus-prev-pane", title: "Focus Previous Pane", systemImage: "arrow.backward.square", shortcut: "⌘[") {
                manager.focusPreviousPane()
            },
            PaletteCommand(id: "focus-next-pane", title: "Focus Next Pane", systemImage: "arrow.forward.square", shortcut: "⌘]") {
                manager.focusNextPane()
            },
            PaletteCommand(id: "toggle-pane-zoom", title: "Toggle Pane Zoom", systemImage: "arrow.up.left.and.arrow.down.right", shortcut: "⇧⌘↩") {
                manager.togglePaneZoom()
            },
            PaletteCommand(id: "equalize-panes", title: "Equalize Panes", systemImage: "rectangle.split.3x1", shortcut: "⌃⌘=") {
                manager.equalizePanes()
            },
            PaletteCommand(id: "resize-pane-up", title: "Resize Pane Up", systemImage: "arrow.up.to.line", shortcut: "⌃⌘↑") {
                manager.resizePaneUp()
            },
            PaletteCommand(id: "resize-pane-down", title: "Resize Pane Down", systemImage: "arrow.down.to.line", shortcut: "⌃⌘↓") {
                manager.resizePaneDown()
            },
            PaletteCommand(id: "resize-pane-left", title: "Resize Pane Left", systemImage: "arrow.left.to.line", shortcut: "⌃⌘←") {
                manager.resizePaneLeft()
            },
            PaletteCommand(id: "resize-pane-right", title: "Resize Pane Right", systemImage: "arrow.right.to.line", shortcut: "⌃⌘→") {
                manager.resizePaneRight()
            },
            PaletteCommand(id: "new-project", title: "New Project", systemImage: "folder.badge.plus", shortcut: "⌘N") {
                manager.newProject()
            },
            PaletteCommand(id: "close-tab", title: "Close Tab", systemImage: "xmark.square", shortcut: "⌘W") {
                manager.closeSelectedTab()
            },
            PaletteCommand(id: "save-file", title: "Save File", systemImage: "square.and.arrow.down", shortcut: "⌘S") {
                manager.saveSelectedFile()
            },
            PaletteCommand(id: "toggle-left-sidebar", title: "Toggle Left Sidebar", systemImage: "sidebar.left", shortcut: "⌘B") {
                manager.toggleLeftSidebar()
            },
            PaletteCommand(id: "toggle-sidebar", title: "Toggle Right Sidebar", systemImage: "sidebar.right", shortcut: "⇧⌘B") {
                manager.toggleSidebar()
            },
            PaletteCommand(id: "toggle-files", title: "Toggle Files Panel", systemImage: "doc.text", shortcut: "⇧⌘E") {
                manager.togglePanel(.files)
            },
            PaletteCommand(id: "toggle-git", title: "Toggle Git Panel", systemImage: "arrow.triangle.branch", shortcut: "⇧⌘G") {
                manager.togglePanel(.git)
            },
            PaletteCommand(id: "toggle-info", title: "Toggle Info Panel", systemImage: "info.circle", shortcut: "⇧⌘I") {
                manager.togglePanel(.info)
            },
            PaletteCommand(id: "next-tab", title: "Next Tab", systemImage: "arrow.right", shortcut: "⇧⌘]") {
                manager.selectNextTab()
            },
            PaletteCommand(id: "prev-tab", title: "Previous Tab", systemImage: "arrow.left", shortcut: "⇧⌘[") {
                manager.selectPreviousTab()
            },
            PaletteCommand(id: "next-project", title: "Next Project", systemImage: "arrow.right.square", shortcut: "⌥⌘]") {
                manager.selectNextProject()
            },
            PaletteCommand(id: "prev-project", title: "Previous Project", systemImage: "arrow.left.square", shortcut: "⌥⌘[") {
                manager.selectPreviousProject()
            },
        ]

        if let project = manager.selectedProject {
            items.append(
                PaletteCommand(id: "close-project", title: "Close Project: \(project.name)", systemImage: "folder.badge.minus") {
                    manager.close(project)
                }
            )
        }

        for (index, project) in manager.projects.enumerated() where project.id != manager.selectedProjectID {
            items.append(
                PaletteCommand(
                    id: "switch-project-\(project.id)",
                    title: "Switch to Project: \(project.name)",
                    systemImage: "folder",
                    shortcut: index < 9 ? "⌘\(index + 1)" : nil
                ) {
                    manager.selectProject(index: index)
                }
            )
        }

        items.append(
            PaletteCommand(id: "settings", title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                openSettings()
            }
        )
        return items
    }

    /// Every open terminal session across all projects, as a jump-to entry.
    /// The directory shows as a subtitle and the project name folds into the
    /// searchable text, so typing a repo or folder name finds its sessions.
    private var sessionCommands: [PaletteCommand] {
        manager.projects.flatMap { project in
            project.sessions.map { session in
                let directory = sessionDirectory(session)
                let search = [session.title, project.name, directory]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return PaletteCommand(
                    id: "session-\(session.id)",
                    verbatimTitle: session.title,
                    systemImage: "terminal",
                    subtitle: directory,
                    section: .session,
                    searchText: search
                ) {
                    manager.revealSession(session)
                }
            }
        }
    }

    /// Tilde-abbreviated working directory for a session's subtitle, or nil
    /// when the shell hasn't reported one yet.
    private func sessionDirectory(_ session: TerminalSession) -> String? {
        guard let dir = session.workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        guard !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    /// The current project's pinned/automatic panel root. Indexing starts only
    /// after the user types, so opening ⌘P for a command stays filesystem-free.
    /// Home is excluded because it is an account boundary, not a project root.
    private var fileIndexRoot: String? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let project = manager.selectedProject
        else { return nil }
        let root: String?
        if let session = project.selectedSession {
            root = project.panelRoot(followingSessionAt: session.currentDirectoryPath).root
        } else if let pinned = project.customDirectory,
                  FileManager.default.fileExists(atPath: pinned) {
            root = pinned
        } else {
            root = nil
        }
        guard let root else { return nil }

        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        return standardizedRoot == home ? nil : root
    }

    private var filtered: [PaletteCommand] {
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return commands + sessionCommands }
        let fuzzyQuery = Self.fuzzyMatcher.prepare(pattern)
        var buffer = Self.fuzzyMatcher.makeBuffer()
        var items = matching(commands, fuzzyQuery, buffer: &buffer)
        items.append(contentsOf: matchingFiles(fuzzyQuery, buffer: &buffer))
        items.append(contentsOf: matching(sessionCommands, fuzzyQuery, buffer: &buffer))
        return items
    }

    /// Rank matches within one section. Concatenating the independently ranked
    /// sections above keeps their layout stable as the query changes.
    private func matching(
        _ commands: [PaletteCommand],
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> [PaletteCommand] {
        var matches: [(command: PaletteCommand, score: Double, order: Int)] = []
        matches.reserveCapacity(commands.count)
        for (order, command) in commands.enumerated() {
            guard let score = fuzzyScore(
                command.searchText ?? command.title,
                query,
                buffer: &buffer
            ) else { continue }
            matches.append((command, score, order))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }
        return matches.map(\.command)
    }

    /// Search every indexed file but materialize only the strongest rows. This
    /// keeps a broad query responsive even in a large project.
    private func matchingFiles(
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> [PaletteCommand] {
        var best: [ScoredProjectFile] = []
        best.reserveCapacity(Self.maxFileResults)
        for file in projectFiles {
            guard let score = fileScore(file, query, buffer: &buffer) else {
                continue
            }
            let match = ScoredProjectFile(file: file, score: score)
            if best.count == Self.maxFileResults,
               let weakest = best.last,
               !ranksBefore(match, weakest) {
                continue
            }
            let index = insertionIndex(for: match, in: best)
            best.insert(match, at: index)
            if best.count > Self.maxFileResults {
                best.removeLast()
            }
        }
        return best.map { match in
            let file = match.file
            return PaletteCommand(
                id: "file-\(file.absolutePath)",
                verbatimTitle: file.name,
                systemImage: "doc",
                subtitle: file.parentPath,
                section: .file,
                searchText: file.relativePath
            ) {
                manager.openFile(file.absolutePath)
            }
        }
    }

    /// Like editor file pickers, a basename match always outranks a match found
    /// only in the directory. Directory-qualified queries still fall back to
    /// scoring the complete project-relative path.
    private func fileScore(
        _ file: ProjectFile,
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        if let basenameScore = fuzzyScore(file.name, query, buffer: &buffer) {
            return 1 + basenameScore
        }
        return fuzzyScore(file.relativePath, query, buffer: &buffer)
    }

    private func insertionIndex(
        for match: ScoredProjectFile,
        in matches: [ScoredProjectFile]
    ) -> Int {
        var lowerBound = 0
        var upperBound = matches.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if ranksBefore(match, matches[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }

    private func ranksBefore(_ lhs: ScoredProjectFile, _ rhs: ScoredProjectFile) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.file.relativePath.localizedStandardCompare(rhs.file.relativePath)
            == .orderedAscending
    }

    /// Score via the library's prepared-query, reusable-buffer UTF-8 API. This
    /// avoids per-candidate lowercasing and heap allocation in the hot path.
    @inline(__always)
    private func fuzzyScore(
        _ candidate: String,
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        var candidate = candidate
        return candidate.withUTF8 { bytes in
            Self.fuzzyMatcher.score(
                utf8: bytes,
                against: query,
                buffer: &buffer
            )?.score
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search commands, files, and sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { handleEscapeFromKeyboard(); return .handled }
                    .onSubmit { runSelected() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            // The field itself only claims its text-height slice of the row,
            // so the rest of the 44pt search bar would fall back to the arrow.
            .contentShape(.rect)
            .pointerStyle(.horizontalText)

            Divider()
                .opacity(0.5)

            results
                .pointerStyle(.default)
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: Theme.background))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
        .onAppear {
            query = ""
            selection = 0
            pointerSelectionController.reset()
            // Defer to the next runloop tick: assigning focus synchronously
            // inside the appearance pass can be dropped before the field
            // editor is ready, which left the palette opening unfocused.
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: query) {
            selection = 0
            // Filtering can rebuild a row under a stationary cursor and emit
            // mouseEntered even though the user never moved the pointer.
            pointerSelectionController.reset()
        }
    }

    /// Result list, computing `filtered` once per render. Headers remain
    /// present even when only one section matches, so the asynchronous file
    /// index cannot shift the rows by adding section chrome later.
    @ViewBuilder
    private var results: some View {
        let items = filtered
        let pattern = query.trimmingCharacters(in: .whitespaces)
        let highlightQuery = pattern.isEmpty ? nil : Self.fuzzyMatcher.prepare(pattern)
        if items.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                            if index == 0 || items[index - 1].section != command.section {
                                sectionHeader(command.section, isFirst: index == 0)
                            }
                            row(command, index: index, highlightQuery: highlightQuery)
                                .id(command.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 322)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) {
                    if items.indices.contains(selection) {
                        proxy.scrollTo(items[selection].id)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: PaletteSection, isFirst: Bool) -> some View {
        Text(section.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, isFirst ? 4 : 10)
            .padding(.bottom, 3)
    }

    private func row(
        _ command: PaletteCommand,
        index: Int,
        highlightQuery: FuzzyQuery?
    ) -> some View {
        let isSelected = index == selection
        return Button {
            run(command)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.accent)) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(attributedTitle(command, highlightQuery: highlightQuery, isSelected: isSelected))
                    .lineLimit(1)
                if let subtitle = command.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 12)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
        )
        .background(
            PaletteRowPointerView(
                onEntered: {
                    if pointerSelectionController.acceptsPointerSelection {
                        selection = index
                    }
                },
                onMoved: {
                    if pointerSelectionController.acceptsPointerSelection {
                        selection = index
                    }
                }
            )
        )
    }

    /// Build title styling only for the visible rows. FuzzyMatch's traceback is
    /// intentionally separate from its allocation-free scorer, so running it
    /// here avoids paying that cost across the entire project index.
    private func attributedTitle(
        _ command: PaletteCommand,
        highlightQuery: FuzzyQuery?,
        isSelected: Bool
    ) -> AttributedString {
        var title = AttributedString(command.title)
        title.font = .system(size: 12.5)
        title.foregroundColor = isSelected ? .primary : .secondary
        guard command.section == .file,
              let highlightQuery
        else { return title }

        let ranges = filenameMatchRanges(for: command, query: highlightQuery)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: title),
                  let upper = AttributedString.Index(range.upperBound, within: title)
            else { continue }
            title[lower..<upper].font = .system(size: 12.5, weight: .semibold)
            title[lower..<upper].foregroundColor = Color(nsColor: Theme.accent)
        }
        return title
    }

    /// Prefer a direct basename traceback. For a directory-qualified query,
    /// trace against the relative path and translate only the ranges that land
    /// inside its filename suffix.
    private func filenameMatchRanges(
        for command: PaletteCommand,
        query: FuzzyQuery
    ) -> [Range<String.Index>] {
        if let ranges = Self.fuzzyMatcher.highlight(command.title, against: query) {
            return ranges
        }
        guard let relativePath = command.searchText,
              relativePath.hasSuffix(command.title),
              let pathRanges = Self.fuzzyMatcher.highlight(relativePath, against: query)
        else { return [] }

        let filenameStart = relativePath.index(
            relativePath.endIndex,
            offsetBy: -command.title.count
        )
        return pathRanges.compactMap { pathRange in
            guard pathRange.upperBound > filenameStart else { return nil }
            let clippedLower = max(pathRange.lowerBound, filenameStart)
            let lowerOffset = relativePath.distance(from: filenameStart, to: clippedLower)
            let upperOffset = relativePath.distance(from: filenameStart, to: pathRange.upperBound)
            guard let lower = command.title.index(
                command.title.startIndex,
                offsetBy: lowerOffset,
                limitedBy: command.title.endIndex
            ),
            let upper = command.title.index(
                command.title.startIndex,
                offsetBy: upperOffset,
                limitedBy: command.title.endIndex
            ) else { return nil }
            return lower..<upper
        }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelected() {
        let items = filtered
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    private func run(_ command: PaletteCommand) {
        dismiss()
        command.action()
    }

    private func dismiss() {
        manager.dismissCommandPalette()
    }

    private func handleEscapeFromKeyboard() {
        if query.isEmpty {
            dismissFromKeyboard()
        } else {
            query = ""
        }
    }

    /// Escape reaches us as AppKit's `cancelOperation:`, which SwiftUI can
    /// dispatch inside a view-update pass — flipping the manager's published
    /// `isCommandPaletteVisible` there logs "Publishing changes from within
    /// view updates". Hop to the next runloop so the removal lands cleanly.
    /// (Return and backdrop taps arrive during normal event handling and can
    /// dismiss synchronously.)
    private func dismissFromKeyboard() {
        DispatchQueue.main.async { dismiss() }
    }

    // MARK: - Project file index

    /// Git provides a fast, ignore-aware index for repositories. A normal
    /// directory falls back to recursive enumeration, still excluding VCS
    /// metadata to match the Files panel.
    private nonisolated static func loadProjectFiles(in root: String) -> [ProjectFile] {
        if let paths = gitProjectFilePaths(in: root) {
            return projectFiles(for: paths, in: root)
        }
        return enumeratedProjectFiles(in: root)
    }

    private nonisolated static func gitProjectFilePaths(in root: String) -> Set<String>? {
        var tracked = GitStatusModel.runGit(
            ["ls-files", "--cached", "--recurse-submodules", "-z"],
            in: root
        )
        // A missing or broken submodule should not disable search for the rest
        // of the repository.
        if tracked.status != 0 {
            tracked = GitStatusModel.runGit(["ls-files", "--cached", "-z"], in: root)
        }
        let untracked = GitStatusModel.runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            in: root
        )
        guard tracked.status == 0, untracked.status == 0 else { return nil }
        return Set(nulSeparatedPaths(tracked.stdout) + nulSeparatedPaths(untracked.stdout))
    }

    private nonisolated static func nulSeparatedPaths(_ output: String) -> [String] {
        output.split(separator: "\0").map(String.init)
    }

    private nonisolated static func projectFiles(
        for relativePaths: Set<String>,
        in root: String
    ) -> [ProjectFile] {
        let fileManager = FileManager.default
        return relativePaths.compactMap { relativePath in
            guard !Task.isCancelled else { return nil }
            let absolutePath = (root as NSString).appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return ProjectFile(
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                absolutePath: absolutePath
            )
        }
        .sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private nonisolated static func enumeratedProjectFiles(in root: String) -> [ProjectFile] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let keySet = Set(keys)
        let rootPrefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [ProjectFile] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keySet),
                  values.isDirectory != true,
                  values.isRegularFile == true
            else { continue }
            guard url.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(url.path.dropFirst(rootPrefix.count))
            files.append(
                ProjectFile(
                    name: url.lastPathComponent,
                    relativePath: relativePath,
                    absolutePath: url.path
                )
            )
        }
        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}

private struct PalettePointerEventMonitor: NSViewRepresentable {
    let controller: PalettePointerSelectionController

    func makeNSView(context: Context) -> PalettePointerMonitorNSView {
        let view = PalettePointerMonitorNSView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: PalettePointerMonitorNSView, context: Context) {
        nsView.controller = controller
    }

    static func dismantleNSView(
        _ nsView: PalettePointerMonitorNSView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
private final class PalettePointerMonitorNSView: NSView {
    weak var controller: PalettePointerSelectionController?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
            [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard window?.isKeyWindow == true else { return }
                self?.controller?.notePointerMoved()
            }
            return event
        }
    }

    func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// AppKit distinguishes a genuine pointer move from the synthetic
/// `mouseEntered` generated when filtering places a new row under the cursor.
private struct PaletteRowPointerView: NSViewRepresentable {
    let onEntered: () -> Void
    let onMoved: () -> Void

    func makeNSView(context: Context) -> PaletteRowPointerNSView {
        let view = PaletteRowPointerNSView()
        view.onEntered = onEntered
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: PaletteRowPointerNSView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onMoved = onMoved
    }
}

private final class PaletteRowPointerNSView: NSView {
    var onEntered: (() -> Void)?
    var onMoved: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeInKeyWindow,
                    .inVisibleRect,
                ],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseMoved(with event: NSEvent) {
        onMoved?()
    }
}
