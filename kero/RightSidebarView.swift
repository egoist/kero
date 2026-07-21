//
//  RightSidebarView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Right sidebar: hidden by default, toggled from the terminal's corner
/// button or ⇧⌘B. Files/Git switch via tabs along its top, otty-style.
struct RightSidebarView: View {
    @ObservedObject var manager: TerminalManager
    @StateObject private var fileTree = FileTreeModel()
    @StateObject private var git = GitStatusModel()
    @StateObject private var info = SessionInfoModel()
    @AppStorage("rightSidebarWidth") private var width: Double = 240

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Path of the file open in the active tab, so the tree can highlight it.
    /// Reactive: `selectedTabID` is published up through the project to `manager`.
    private var openFilePath: String? {
        if case .file(let file)? = manager.selectedProject?.selectedTab {
            return file.path
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if manager.isPanelVisible {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 1)

                VStack(spacing: 0) {
                    tabBar
                    switch manager.panelTab {
                    case .files:
                        FileTreePanel(
                            model: fileTree,
                            session: manager.selectedSession,
                            currentFilePath: openFilePath,
                            openFile: { manager.openFile($0) },
                            onRename: { manager.fileRenamed(from: $0, to: $1) }
                        )
                    case .git:
                        GitPanel(
                            model: git,
                            session: manager.selectedSession,
                            openFile: { manager.openFile($0) },
                            openDiff: { entry, staged in
                                manager.openDiff(
                                    repoRoot: git.repoRoot,
                                    path: entry.path,
                                    staged: staged,
                                    untracked: entry.isUntracked,
                                    origPath: entry.origPath
                                )
                            }
                        )
                    case .info:
                        InfoPanel(model: info, session: manager.selectedSession)
                    }
                }
                .frame(width: width)
                .background(Color(nsColor: Theme.sidebar))
            }
        }
        .overlay(alignment: .leading) {
            if manager.isPanelVisible {
                SidebarResizeHandle(
                    edge: .leading,
                    width: $width,
                    range: 180...500,
                    defaultWidth: 240
                )
            }
        }
        .onAppear(perform: syncModels)
        .onReceive(refreshTimer) { _ in syncModels() }
        .onChange(of: manager.isPanelVisible) { syncModels() }
        .onChange(of: manager.panelTab) { syncModels() }
        .onChange(of: manager.selectedSession?.id) { syncModels() }
        // A `cd` in the terminal publishes the new cwd immediately (OSC 7 →
        // session.workingDirectory); resync at once instead of waiting for the
        // next refreshTimer tick, which is what made the panel lag the change.
        .onChange(of: manager.selectedSession?.workingDirectory) { syncModels() }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.info, systemImage: "info.circle", title: "Info", help: "Info (⇧⌘I)")
            tabButton(.files, systemImage: "folder", title: "Files", help: "Files (⇧⌘E)")
            tabButton(.git, systemImage: "arrow.triangle.branch", title: "Git", help: "Git (⇧⌘G)")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func tabButton(_ panel: RightPanel, systemImage: String, title: String, help: String) -> some View {
        let isActive = manager.panelTab == panel
        return Button {
            manager.panelTab = panel
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: isActive ? .medium : .regular))
            }
            .foregroundStyle(isActive ? .primary : .tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func syncModels() {
        guard let session = manager.selectedSession, manager.isPanelVisible else { return }
        let root = session.currentDirectoryPath
        switch manager.panelTab {
        case .files: fileTree.sync(root: root)
        case .git: git.sync(root: root)
        case .info:
            info.sync(root: root, shellName: session.shellName, shellPid: session.shellPid)
        }
    }
}

// MARK: - Shared panel chrome

private struct PanelHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - File tree

private struct FileTreePanel: View {
    @ObservedObject var model: FileTreeModel
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelHeader(title: model.rootName, subtitle: model.rootPath)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.items) { item in
                        FileTreeRow(
                            model: model, item: item, session: session,
                            currentFilePath: currentFilePath,
                            openFile: openFile, onRename: onRename
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct FileTreeRow: View {
    @ObservedObject var model: FileTreeModel
    let item: FileTreeModel.Item
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void

    @State private var isHovering = false
    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { model.renamingPath == item.path }

    /// The file open in the active tab, so it reads as selected in the tree.
    private var isCurrent: Bool { !item.isDirectory && item.path == currentFilePath }

    var body: some View {
        if item.isDraft {
            // The transient new-file/folder input row: no hover/menu, no
            // backing file to act on.
            draftRow
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isCurrent ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.05) : .clear))
                )
                .onHover { isHovering = $0 }
                .contextMenu { rowMenu }
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if !item.isDirectory {
            Button("Open") {
                openFile(item.path)
            }
        }
        Button("Open in Default App") {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if item.isDirectory {
            Button("cd Here") {
                session?.sendCommand("cd " + shellQuote(item.path) + "\n")
            }
            Divider()
            Button("New File…") {
                model.beginNewFile(in: item.path)
            }
            Button("New Folder…") {
                model.beginNewFolder(in: item.path)
            }
        }
        Divider()
        Button("Rename") {
            model.beginRename(item)
        }
        Button("Move to Trash", role: .destructive) {
            model.moveToTrash(item)
        }
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isRenaming else { return }
        let oldPath = item.path
        if let newPath = model.rename(item, to: editingName) {
            onRename(oldPath, newPath)
        }
    }

    /// Commits the inline new-file/folder input, opening a newly created file.
    /// Guarded so the commit-on-blur after Enter/Escape is a no-op.
    private func commitDraft() {
        guard item.isDraft, model.draft != nil else { return }
        if let created = model.commitDraft(name: editingName) {
            openFile(created)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRenaming {
            renameRow
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button {
            if item.isDirectory {
                model.toggle(item)
            } else {
                openFile(item.path)
            }
        } label: {
            HStack(spacing: 5) {
                leadingGlyphs
                Text(item.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(item.name.hasPrefix(".") ? .tertiary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(item.depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var renameRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField("Name")
                .onSubmit { commitRename() }
                .onKeyPress(.escape) { model.cancelRename(); return .handled }
                .onChange(of: fieldFocused) {
                    // Commit on blur (Finder-style); unchanged names no-op.
                    if !fieldFocused { commitRename() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = item.name
            focusField()
        }
    }

    private var draftRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(item.isDirectory ? "Folder name" : "File name")
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) { model.cancelDraft(); return .handled }
                .onChange(of: fieldFocused) {
                    // Blur commits a typed name, cancels an empty one (VS Code).
                    if !fieldFocused { commitDraft() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = ""
            focusField()
        }
    }

    private func nameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $editingName)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: Theme.cursor).opacity(0.7), lineWidth: 1)
            )
    }

    /// Grab focus on the next runloop tick — a context menu is still
    /// dismissing when the input row appears, and a synchronous focus can be
    /// stolen back as it tears down.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var leadingGlyphs: some View {
        Group {
            if item.isDirectory && !item.isDraft {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.isExpanded(item) ? 90 : 0))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(item.isDirectory ? Color(nsColor: Theme.cursor).opacity(0.8) : Color.secondary)
                .frame(width: 14)
        }
    }
}

// MARK: - Git panel

private struct GitPanel: View {
    @ObservedObject var model: GitStatusModel
    let session: TerminalSession?
    let openFile: (String) -> Void
    let openDiff: (_ entry: GitStatusModel.Entry, _ staged: Bool) -> Void

    @State private var commitMessage = ""
    @State private var pendingDiscard: GitStatusModel.Entry?
    @State private var confirmDiscardAll = false
    @State private var mergeCollapsed = false
    @State private var stagedCollapsed = false
    @State private var changesCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if !model.isRepo {
                placeholder(icon: "arrow.triangle.branch", text: "Not a git repository")
            } else {
                if let error = model.lastError {
                    errorBar(error)
                }
                commitBox
                if model.totalChangeCount == 0 {
                    placeholder(icon: "checkmark.circle", text: "Working tree clean")
                } else {
                    changeList
                }
            }
        }
        .confirmationDialog(
            discardTitle(for: pendingDiscard),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingDiscard?.isUntracked == true ? "Move to Trash" : "Discard Changes",
                   role: .destructive) {
                if let entry = pendingDiscard { model.discard(entry) }
                pendingDiscard = nil
            }
        }
        .confirmationDialog(
            "Discard all \(model.changedEntries.count) changes? Untracked files move to the Trash.",
            isPresented: $confirmDiscardAll,
            titleVisibility: .visible
        ) {
            Button("Discard All Changes", role: .destructive) {
                model.discardAllChanges()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.cursor))
            PanelHeader(
                title: model.isRepo ? (model.branch ?? "…") : "Git",
                subtitle: model.rootPath
            )
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            if model.isRepo {
                if model.behind > 0 {
                    badge("↓\(model.behind)")
                }
                if model.ahead > 0 {
                    badge("↑\(model.ahead)")
                }
                headerButton("arrow.clockwise", help: "Refresh", disabled: false) {
                    model.refresh()
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var moreMenu: some View {
        Menu {
            Button("Pull") { model.pull() }
                .disabled(model.isBusy || !model.hasUpstream)
            Button(model.hasUpstream ? "Push" : "Publish Branch") { model.push() }
                .disabled(model.isBusy)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Actions…")
    }

    private func headerButton(
        _ systemImage: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField(commitFieldPlaceholder, text: $commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .lineLimit(1...4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .onSubmit(performCommit)

            if showSyncButton {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncButtonTitle,
                    enabled: !model.isBusy,
                    help: "Pull remote commits, then push local ones"
                ) {
                    model.syncChanges()
                }
            } else {
                actionButton(
                    icon: "checkmark",
                    title: commitButtonTitle,
                    enabled: canCommit,
                    help: model.stagedEntries.isEmpty
                        ? "Stage all changes and commit"
                        : "Commit staged changes",
                    action: performCommit
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func actionButton(
        icon: String, title: String, enabled: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Theme.cursor).opacity(enabled ? 0.85 : 0.3))
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var commitFieldPlaceholder: String {
        if let branch = model.branch {
            return "Message (⏎ to commit on \"\(branch)\")"
        }
        return "Message (⏎ to commit)"
    }

    private var showSyncButton: Bool {
        model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0)
    }

    private var syncButtonTitle: String {
        var title = "Sync Changes"
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }

    private var commitButtonTitle: String {
        model.stagedEntries.isEmpty && model.totalChangeCount > 0 ? "Commit All" : "Commit"
    }

    private var canCommit: Bool {
        !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.totalChangeCount > 0
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func performCommit() {
        guard canCommit else { return }
        model.commit(message: commitMessage)
        commitMessage = ""
    }

    // MARK: Change list

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !model.mergeEntries.isEmpty {
                    GitSectionHeader(
                        title: "MERGE CHANGES",
                        count: model.mergeEntries.count,
                        isCollapsed: $mergeCollapsed,
                        actions: []
                    )
                    if !mergeCollapsed {
                        ForEach(model.mergeEntries, id: \.mergeRowID) { entry in
                            row(entry, status: "U", kind: .merge)
                        }
                    }
                }
                if !model.stagedEntries.isEmpty {
                    GitSectionHeader(
                        title: "STAGED CHANGES",
                        count: model.stagedEntries.count,
                        isCollapsed: $stagedCollapsed,
                        actions: [
                            .init(systemImage: "minus", help: "Unstage All Changes") {
                                model.unstageAll()
                            }
                        ]
                    )
                    if !stagedCollapsed {
                        ForEach(model.stagedEntries, id: \.stagedRowID) { entry in
                            row(entry, status: entry.staged, kind: .staged)
                        }
                    }
                }
                if !model.changedEntries.isEmpty {
                    GitSectionHeader(
                        title: "CHANGES",
                        count: model.changedEntries.count,
                        isCollapsed: $changesCollapsed,
                        actions: [
                            .init(systemImage: "arrow.uturn.backward", help: "Discard All Changes") {
                                confirmDiscardAll = true
                            },
                            .init(systemImage: "plus", help: "Stage All Changes") {
                                model.stageAll()
                            },
                        ]
                    )
                    if !changesCollapsed {
                        ForEach(model.changedEntries, id: \.changedRowID) { entry in
                            row(entry, status: entry.unstaged, kind: .unstaged)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private func row(
        _ entry: GitStatusModel.Entry, status: Character, kind: GitEntryRow.Kind
    ) -> some View {
        GitEntryRow(
            entry: entry,
            status: status,
            kind: kind,
            disabled: model.isBusy,
            openDiff: { openDiff(entry, kind == .staged) },
            openFile: { openIfPossible(entry) },
            stage: { model.stage(entry) },
            unstage: { model.unstage(entry) },
            discard: { pendingDiscard = entry },
            absolutePath: model.absolutePath(for: entry)
        )
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry) {
        let path = model.absolutePath(for: entry)
        guard FileManager.default.fileExists(atPath: path) else { return }
        openFile(path)
    }

    private func discardTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "" }
        return entry.isUntracked
            ? "Delete \(entry.fileName)? It is untracked and will move to the Trash."
            : "Discard changes in \(entry.fileName)?"
    }

    // MARK: Bits

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 10.5))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.82, green: 0.60, blue: 0.13).opacity(0.08))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

private struct GitSectionHeader: View {
    struct Action: Identifiable {
        let id = UUID()
        let systemImage: String
        let help: String
        let perform: () -> Void
    }

    let title: String
    let count: Int
    @Binding var isCollapsed: Bool
    let actions: [Action]

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                ForEach(actions) { action in
                    Button(action: action.perform) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help(action.help)
                }
            }

            Spacer(minLength: 0)

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        // Fixed height so the taller hover buttons don't grow the header.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .onHover { isHovering = $0 }
    }
}

private struct GitEntryRow: View {
    enum Kind {
        case merge, staged, unstaged
    }

    let entry: GitStatusModel.Entry
    let status: Character
    let kind: Kind
    let disabled: Bool
    let openDiff: () -> Void
    let openFile: () -> Void
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let absolutePath: String

    @State private var isHovering = false

    var body: some View {
        Button(action: openDiff) {
            HStack(spacing: 7) {
                Text(String(status))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .frame(width: 12)
                Text(entry.fileName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .strikethrough(status == "D")
                    .lineLimit(1)
                    .layoutPriority(1)
                if !isHovering {
                    Text(entry.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if isHovering && !disabled {
                    hoverActions
                }
            }
            // Fixed height so the taller hover buttons don't grow the row.
            .frame(height: 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu { menu }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            switch kind {
            case .merge:
                rowButton("plus", help: "Mark Resolved (Stage)", action: stage)
            case .staged:
                rowButton("minus", help: "Unstage Changes", action: unstage)
            case .unstaged:
                rowButton("arrow.uturn.backward", help: "Discard Changes", action: discard)
                rowButton("plus", help: "Stage Changes", action: stage)
            }
        }
    }

    private func rowButton(
        _ systemImage: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open Changes") { openDiff() }
        Button("Open File") { openFile() }
        Divider()
        switch kind {
        case .merge:
            Button("Mark Resolved (Stage)") { stage() }
        case .staged:
            Button("Unstage Changes") { unstage() }
        case .unstaged:
            Button("Stage Changes") { stage() }
            Button(entry.isUntracked ? "Delete File…" : "Discard Changes…") { discard() }
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absolutePath, forType: .string)
        }
    }

    private var statusColor: Color {
        switch status {
        case "M": return Color(red: 0.82, green: 0.60, blue: 0.13)
        case "A", "?": return Color(red: 0.25, green: 0.73, blue: 0.31)
        case "D": return Color(red: 1.0, green: 0.48, blue: 0.45)
        case "R", "C": return Color(red: 0.35, green: 0.65, blue: 1.0)
        case "U": return Color(red: 0.74, green: 0.55, blue: 1.0)
        default: return .secondary
        }
    }
}

// MARK: - Info panel

/// Session dashboard: working directory (with reveal/open/copy actions),
/// processes running under the shell, and ports they are listening on.
private struct InfoPanel: View {
    @ObservedObject var model: SessionInfoModel
    let session: TerminalSession?

    @State private var directoryCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    private static let vsCodeURL = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    directorySection
                    processesSection
                    portsSection
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.cursor))
            PanelHeader(
                title: model.shellName.isEmpty ? "Session" : model.shellName,
                subtitle: model.shellPid > 0 ? "pid \(String(model.shellPid))" : nil
            )
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Directory

    @ViewBuilder
    private var directorySection: some View {
        GitSectionHeader(
            title: "DIRECTORY", count: 0, isCollapsed: $directoryCollapsed, actions: []
        )
        if !directoryCollapsed {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.rootPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.rootPath)
                    .contextMenu {
                        Button("Copy Path") { copyPath() }
                    }

                HStack(spacing: 4) {
                    actionButton("Finder", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: model.rootPath)]
                        )
                    }
                    if let vsCode = Self.vsCodeURL {
                        actionButton("VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                            NSWorkspace.shared.open(
                                [URL(fileURLWithPath: model.rootPath)],
                                withApplicationAt: vsCode,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                        }
                    }
                    actionButton("Copy", systemImage: "doc.on.doc") {
                        copyPath()
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.rootPath, forType: .string)
    }

    private func actionButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title == "Copy" ? "Copy Path" : "Open in \(title)")
    }

    // MARK: Processes

    @ViewBuilder
    private var processesSection: some View {
        GitSectionHeader(
            title: "PROCESSES",
            count: model.processes.count,
            isCollapsed: $processesCollapsed,
            actions: []
        )
        if !processesCollapsed {
            if model.processes.isEmpty {
                emptyRow("No running processes")
            } else {
                ForEach(model.processes) { process in
                    InfoProcessRow(process: process) { force in
                        model.kill(process.pid, force: force)
                    }
                }
            }
        }
    }

    // MARK: Ports

    @ViewBuilder
    private var portsSection: some View {
        GitSectionHeader(
            title: "PORTS",
            count: model.ports.count,
            isCollapsed: $portsCollapsed,
            actions: []
        )
        if !portsCollapsed {
            if model.ports.isEmpty {
                emptyRow("No listening ports")
            } else {
                ForEach(model.ports) { port in
                    InfoPortRow(port: port) { force in
                        model.kill(port.pid, force: force)
                    }
                }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct InfoProcessRow: View {
    let process: SessionInfoModel.ProcessItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                .frame(width: 5, height: 5)
            Text(process.name)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(process.executable)
            Text(String(process.pid))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    kill(false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Terminate Process")
            } else {
                Text(String(format: "%.0f%% · %@", process.cpu, process.memoryLabel))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        // Fixed height so the taller hover button doesn't grow the row.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Terminate") { kill(false) }
            Button("Force Kill") { kill(true) }
            Divider()
            Button("Copy PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.pid)", forType: .string)
            }
            Button("Copy Executable Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.executable, forType: .string)
            }
        }
    }
}

private struct InfoPortRow: View {
    let port: SessionInfoModel.PortItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    private var urlString: String { "http://localhost:\(port.port)" }

    var body: some View {
        Button {
            if let url = port.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 12)
                Text(String(port.port))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text(port.processName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            // Fixed height to match the other sidebar rows.
            .frame(height: 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Open \(urlString)")
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Browser") {
                if let url = port.url {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
            Divider()
            Button("Kill Process (\(port.processName))") { kill(false) }
        }
    }
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
