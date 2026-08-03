import SwiftUI
import UIKit

enum TerminalProjectPanel: String, CaseIterable, Identifiable {
    case files = "Files"
    case git = "Git"

    var id: Self { self }
}

struct TerminalProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var project: RemoteProjectModel
    @State private var selectedPanel: TerminalProjectPanel

    init(
        session: TerminalSessionModel,
        initialPanel: TerminalProjectPanel
    ) {
        _project = ObservedObject(wrappedValue: session.remoteProject)
        _selectedPanel = State(initialValue: initialPanel)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Project panel", selection: $selectedPanel) {
                    ForEach(TerminalProjectPanel.allCases) { panel in
                        Text(panel.rawValue).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("project-panel-picker")
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch selectedPanel {
                case .files:
                    RemoteFilesView(project: project)
                case .git:
                    RemoteGitView(project: project)
                }
            }
            .navigationTitle(project.projectName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        refresh()
                    }
                    .disabled(
                        project.isLoadingFiles
                            || project.isLoadingGit
                            || project.isRunningGitAction
                    )
                }
            }
        }
        .task(id: selectedPanel) {
            switch selectedPanel {
            case .files where project.files.isEmpty:
                await project.refreshFiles()
            case .git where !project.hasLoadedGit:
                await project.refreshGit()
            default:
                break
            }
        }
    }

    private func refresh() {
        Task {
            switch selectedPanel {
            case .files:
                await project.refreshFiles()
            case .git:
                await project.refreshGit()
            }
        }
    }
}

private struct RemoteFilesView: View {
    @ObservedObject var project: RemoteProjectModel

    var body: some View {
        Group {
            if project.isLoadingFiles && project.files.isEmpty {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if project.files.isEmpty {
                ContentUnavailableView {
                    Label(
                        project.filesError == nil
                            ? "No Files"
                            : "Couldn’t Load Files",
                        systemImage: project.filesError == nil
                            ? "folder"
                            : "folder.badge.questionmark"
                    )
                } description: {
                    Text(
                        project.filesError
                            ?? "This project directory is empty."
                    )
                } actions: {
                    Button("Try Again") {
                        Task {
                            await project.refreshFiles()
                        }
                    }
                }
            } else {
                List {
                    Section {
                        ForEach(project.files) { item in
                            RemoteFileRow(
                                project: project,
                                item: item
                            )
                        }
                    } header: {
                        if let root = project.projectRoot {
                            Label(root, systemImage: "folder")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textCase(nil)
                                .accessibilityIdentifier(
                                    "remote-project-root"
                                )
                        }
                    }
                }
                .listStyle(.plain)
                .overlay(alignment: .top) {
                    if project.isLoadingFiles {
                        ProgressView()
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
            }
        }
    }
}

private struct RemoteFileRow: View {
    @ObservedObject var project: RemoteProjectModel
    let item: RemoteFileItem

    var body: some View {
        Group {
            if item.isDirectory {
                Button {
                    Task {
                        await project.toggleDirectory(item)
                    }
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    RemoteFilePreviewView(
                        project: project,
                        item: item
                    )
                } label: {
                    rowLabel
                }
            }
        }
        .accessibilityIdentifier("remote-file-\(item.path)")
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: CGFloat(item.depth) * 16)

            if item.isDirectory {
                Image(
                    systemName: project.isExpanded(item)
                        ? "chevron.down"
                        : "chevron.right"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            } else {
                Color.clear.frame(width: 10)
            }

            Image(
                systemName: item.isDirectory
                    ? "folder.fill"
                    : fileSymbol
            )
            .foregroundStyle(item.isDirectory ? .blue : .secondary)
            .frame(width: 20)

            Text(item.name)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var fileSymbol: String {
        switch (item.name as NSString).pathExtension.lowercased() {
        case "swift":
            "swift"
        case "md", "txt":
            "doc.text"
        case "json", "yaml", "yml", "toml":
            "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp":
            "photo"
        default:
            "doc"
        }
    }
}

private struct RemoteFilePreviewView: View {
    @ObservedObject var project: RemoteProjectModel
    let item: RemoteFileItem

    @State private var contents: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let contents {
                ScrollView([.horizontal, .vertical]) {
                    Text(contents.isEmpty ? "This file is empty." : contents)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                        .padding()
                }
                .privacySensitive()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn’t Open File",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading \(item.name)…")
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                contents = try await project.loadFile(item)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RemoteGitView: View {
    @ObservedObject var project: RemoteProjectModel

    @State private var commitMessage = ""
    @State private var searchText = ""
    @State private var showBranches = false
    @State private var showOperation = false
    @State private var pendingDiscard: RemoteGitEntry?
    @State private var pendingDiscardAll: [RemoteGitEntry] = []
    @State private var confirmDiscardAll = false

    var body: some View {
        Group {
            if project.isLoadingGit && project.git == nil {
                ProgressView("Loading Git status…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let git = project.git {
                gitList(git)
            } else if project.canInitializeGit {
                ContentUnavailableView {
                    Label(
                        "No Git Repository",
                        systemImage: "arrow.triangle.branch"
                    )
                } description: {
                    VStack(spacing: 8) {
                        Text(
                            "Initialize the terminal’s current directory "
                                + "to start tracking changes."
                        )
                        if let error = project.gitError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } actions: {
                    Button("Initialize Repository") {
                        Task {
                            await project.initializeRepository()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(project.isRunningGitAction)
                    .accessibilityIdentifier("initialize-git-repository")
                }
            } else {
                ContentUnavailableView {
                    Label(
                        "Couldn’t Load Git",
                        systemImage: "arrow.triangle.branch"
                    )
                } description: {
                    Text(
                        project.gitError
                            ?? "The remote Git status could not be loaded."
                    )
                } actions: {
                    Button("Try Again") {
                        Task {
                            await project.refreshGit()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showBranches) {
            RemoteGitBranchesView(project: project)
        }
        .sheet(isPresented: $showOperation) {
            RemoteGitOperationView(project: project)
        }
        .confirmationDialog(
            discardTitle,
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: {
                    if !$0 {
                        pendingDiscard = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                guard let entry = pendingDiscard else {
                    return
                }
                pendingDiscard = nil
                Task {
                    await project.discard(entry)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDiscard = nil
            }
        } message: {
            Text(discardMessage)
        }
        .confirmationDialog(
            "Discard \(pendingDiscardAll.count) reviewed changes?",
            isPresented: $confirmDiscardAll,
            titleVisibility: .visible
        ) {
            Button("Discard All Changes", role: .destructive) {
                let entries = pendingDiscardAll
                pendingDiscardAll = []
                Task {
                    await project.discardChanges(entries)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDiscardAll = []
            }
        } message: {
            Text(
                "Tracked files will be restored and untracked files will "
                    + "be permanently deleted from the remote host. "
                    + "Only the reviewed files in this confirmation are affected."
            )
        }
    }

    private func gitList(_ git: RemoteGitSnapshot) -> some View {
        List {
            Section {
                repositoryHeader(git)
                repositoryActions(git)
            }

            if let operation = git.repositoryOperation {
                Section {
                    Label(
                        "\(operation) in progress",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Commit") {
                TextField(
                    git.branch == "Detached HEAD"
                        ? "Commit message"
                        : "Message on \(git.branch)",
                    text: $commitMessage,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .autocorrectionDisabled()
                .accessibilityLabel("Commit message")
                .accessibilityIdentifier("git-commit-message")

                HStack(spacing: 8) {
                    Button {
                        performCommit(
                            includeAll: false,
                            amend: false
                        )
                    } label: {
                        Text(commitButtonTitle(git))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit(git, includeAll: false))
                    .accessibilityIdentifier("git-commit-staged")

                    Menu {
                        Button(
                            "Stage All & Commit",
                            systemImage: "checkmark.circle"
                        ) {
                            performCommit(
                                includeAll: true,
                                amend: false
                            )
                        }
                        .disabled(!canCommit(git, includeAll: true))

                        Divider()

                        Button(
                            "Amend Last Commit",
                            systemImage: "pencil"
                        ) {
                            performCommit(
                                includeAll: false,
                                amend: true
                            )
                        }
                        .disabled(!canAmend(git, includeAll: false))

                        Button(
                            "Stage All & Amend",
                            systemImage: "pencil.and.list.clipboard"
                        ) {
                            performCommit(
                                includeAll: true,
                                amend: true
                            )
                        }
                        .disabled(!canAmend(git, includeAll: true))
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 36, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Commit options")
                }
            }

            if git.entries.isEmpty {
                Section {
                    Label(
                        "Working tree clean",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                }
            } else if filteredEntries(git.entries).isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Matching Changes",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(
                            "Try a different file name or path."
                        )
                    )
                }
            }

            gitSection(
                "Conflicts",
                entries: filteredEntries(git.conflicts),
                staged: false,
                tint: .red,
                bulkAction: nil
            )
            gitSection(
                "Staged",
                entries: filteredEntries(git.staged),
                staged: true,
                tint: .green,
                bulkAction: RemoteGitBulkAction(
                    title: "Unstage All",
                    symbol: "minus",
                    action: {
                        Task {
                            await project.unstageAll()
                        }
                    }
                )
            )
            gitSection(
                "Changes",
                entries: filteredEntries(git.changed),
                staged: false,
                tint: .orange,
                bulkAction: RemoteGitBulkAction(
                    title: "Stage All",
                    symbol: "plus",
                    action: {
                        Task {
                            await project.stageAll()
                        }
                    }
                )
            )

            if !git.recentCommits.isEmpty {
                Section("Recent Commits") {
                    ForEach(filteredCommits(git.recentCommits)) { commit in
                        NavigationLink {
                            RemoteGitCommitView(
                                project: project,
                                commit: commit
                            )
                        } label: {
                            RemoteGitCommitRow(commit: commit)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Filter changes"
        )
        .overlay {
            if project.isRunningGitAction {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView(
                            project.gitOperation?.statusText
                                ?? "Running Git action…"
                        )
                        .padding(16)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let operation = project.gitOperation {
                Button {
                    showOperation = true
                } label: {
                    HStack(spacing: 9) {
                        operationSymbol(operation)
                        Text(operation.statusText)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("git-operation-status")
            }
        }
    }

    private func repositoryHeader(
        _ git: RemoteGitSnapshot
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                showBranches = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(git.branch)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch branch, current branch \(git.branch)")
            .accessibilityIdentifier("git-branch-picker")

            Spacer(minLength: 4)

            if git.ahead > 0 {
                Label("\(git.ahead)", systemImage: "arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(git.ahead) commits ahead")
            }
            if git.behind > 0 {
                Label("\(git.behind)", systemImage: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(git.behind) commits behind")
            }
        }
    }

    private func repositoryActions(
        _ git: RemoteGitSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder")
                Text(git.repositoryRoot)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let upstream = git.upstream {
                Label(upstream, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        if git.upstream == nil,
                           git.remotes.count > 1 {
                            showBranches = true
                        } else {
                            await project.syncChanges()
                        }
                    }
                } label: {
                    Label(
                        git.upstream == nil ? "Publish" : "Sync",
                        systemImage: git.upstream == nil
                            ? "icloud.and.arrow.up"
                            : "arrow.triangle.2.circlepath"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(
                    project.isRunningGitAction
                        || git.branch == "Detached HEAD"
                )
                .accessibilityIdentifier("git-sync")

                Menu {
                    Button("Fetch", systemImage: "arrow.down.circle") {
                        Task {
                            await project.fetch()
                        }
                    }
                    .disabled(git.remotes.isEmpty)

                    Button("Pull", systemImage: "arrow.down") {
                        Task {
                            await project.pull()
                        }
                    }
                    .disabled(git.upstream == nil)

                    if git.upstream != nil {
                        Button("Push", systemImage: "arrow.up") {
                            Task {
                                await project.push()
                            }
                        }
                    } else if git.remotes.count == 1 {
                        Button(
                            "Publish Branch",
                            systemImage: "icloud.and.arrow.up"
                        ) {
                            Task {
                                await project.push()
                            }
                        }
                    } else if !git.remotes.isEmpty {
                        Menu("Publish Branch To") {
                            ForEach(git.remotes, id: \.self) { remote in
                                Button(remote) {
                                    Task {
                                        await project.push(to: remote)
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Button(
                        "Stash All Changes",
                        systemImage: "archivebox"
                    ) {
                        Task {
                            await project.stash()
                        }
                    }
                    .disabled(git.totalChangeCount == 0)

                    Button(
                        git.stashCount == 0
                            ? "Pop Stash"
                            : "Pop Stash (\(git.stashCount))",
                        systemImage: "archivebox.fill"
                    ) {
                        Task {
                            await project.popStash()
                        }
                    }
                    .disabled(git.stashCount == 0)

                    Divider()

                    Button(
                        "Branches",
                        systemImage: "arrow.triangle.branch"
                    ) {
                        showBranches = true
                    }

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            await project.refreshGit()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("More source control actions")
                .accessibilityIdentifier("git-action-menu")
            }
        }
    }

    @ViewBuilder
    private func gitSection(
        _ title: String,
        entries: [RemoteGitEntry],
        staged: Bool,
        tint: Color,
        bulkAction: RemoteGitBulkAction?
    ) -> some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    NavigationLink {
                        RemoteGitDiffView(
                            project: project,
                            entry: entry,
                            staged: staged
                        )
                    } label: {
                        RemoteGitEntryLabel(
                            entry: entry,
                            staged: staged,
                            tint: tint
                        )
                    }
                    .accessibilityIdentifier(
                        "remote-git-\(staged ? "staged" : "changed")-\(entry.path)"
                    )
                    .swipeActions(
                        edge: .trailing,
                        allowsFullSwipe: true
                    ) {
                        if staged {
                            Button("Unstage", systemImage: "minus") {
                                Task {
                                    await project.unstage(entry)
                                }
                            }
                            .tint(.orange)
                        } else {
                            Button("Stage", systemImage: "plus") {
                                Task {
                                    await project.stage(entry)
                                }
                            }
                            .tint(.green)
                        }
                    }
                    .swipeActions(
                        edge: .leading,
                        allowsFullSwipe: false
                    ) {
                        if !staged {
                            Button(
                                "Discard",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                pendingDiscard = entry
                            }
                        }
                    }
                    .contextMenu {
                        if staged {
                            Button("Unstage", systemImage: "minus") {
                                Task {
                                    await project.unstage(entry)
                                }
                            }
                        } else {
                            Button("Stage", systemImage: "plus") {
                                Task {
                                    await project.stage(entry)
                                }
                            }
                            Button(
                                "Discard Changes…",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                pendingDiscard = entry
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(entries.count)")
                        .foregroundStyle(.secondary)
                    if let bulkAction {
                        Button(
                            bulkAction.title,
                            systemImage: bulkAction.symbol,
                            action: bulkAction.action
                        )
                        .labelStyle(.iconOnly)
                    }
                    if title == "Changes" {
                        Button(
                            "Discard All Changes",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            pendingDiscardAll = entries
                            confirmDiscardAll = true
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }

    private func filteredEntries(
        _ entries: [RemoteGitEntry]
    ) -> [RemoteGitEntry] {
        guard !searchText.isEmpty else {
            return entries
        }
        return entries.filter {
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func filteredCommits(
        _ commits: [RemoteGitCommit]
    ) -> [RemoteGitCommit] {
        guard !searchText.isEmpty else {
            return commits
        }
        return commits.filter {
            $0.subject.localizedCaseInsensitiveContains(searchText)
                || $0.author.localizedCaseInsensitiveContains(searchText)
                || $0.shortHash.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func commitButtonTitle(
        _ git: RemoteGitSnapshot
    ) -> String {
        git.staged.isEmpty
            ? "Commit Staged"
            : "Commit \(git.staged.count) Staged"
    }

    private func canCommit(
        _ git: RemoteGitSnapshot,
        includeAll: Bool
    ) -> Bool {
        !project.isRunningGitAction
            && git.conflicts.isEmpty
            && !commitMessage.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && (includeAll
                ? !git.entries.isEmpty
                : !git.staged.isEmpty)
    }

    private func canAmend(
        _ git: RemoteGitSnapshot,
        includeAll: Bool
    ) -> Bool {
        git.hasHead
            && !project.isRunningGitAction
            && git.conflicts.isEmpty
            && !commitMessage.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && (!includeAll || !git.entries.isEmpty)
    }

    private func performCommit(
        includeAll: Bool,
        amend: Bool
    ) {
        let message = commitMessage
        Task {
            if await project.commit(
                message: message,
                includeAll: includeAll,
                amend: amend
            ) {
                commitMessage = ""
            }
        }
    }

    @ViewBuilder
    private func operationSymbol(
        _ operation: RemoteGitOperation
    ) -> some View {
        switch operation.state {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var discardTitle: String {
        guard let entry = pendingDiscard else {
            return "Discard changes?"
        }
        return entry.isUntracked
            ? "Delete \(entry.fileName)?"
            : "Discard changes in \(entry.fileName)?"
    }

    private var discardMessage: String {
        guard let entry = pendingDiscard else {
            return ""
        }
        if entry.isUntracked || entry.isWorktreeCopy {
            return "This untracked file will be permanently deleted "
                + "from the remote host. This can’t be undone."
        }
        return "The remote file will be restored to its Git version. "
            + "This can’t be undone from Kero."
    }
}

private struct RemoteGitBulkAction {
    let title: String
    let symbol: String
    let action: () -> Void
}

private struct RemoteGitEntryLabel: View {
    let entry: RemoteGitEntry
    let staged: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityLabel(statusDescription)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !entry.directory.isEmpty {
                    Text(entry.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var status: String {
        if entry.isConflict {
            return "!"
        }
        if entry.isUntracked {
            return "U"
        }
        let value = staged ? entry.stagedStatus : entry.worktreeStatus
        return String(value)
    }

    private var statusDescription: String {
        switch status {
        case "!":
            "Conflict"
        case "U":
            "Untracked"
        case "M":
            "Modified"
        case "A":
            "Added"
        case "D":
            "Deleted"
        case "R":
            "Renamed"
        case "C":
            "Copied"
        default:
            "Changed"
        }
    }
}

private struct RemoteGitDiffView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var project: RemoteProjectModel
    let entry: RemoteGitEntry
    let staged: Bool

    @State private var diff: String?
    @State private var errorMessage: String?
    @State private var confirmDiscard = false

    var body: some View {
        Group {
            if let diff {
                ScrollView([.horizontal, .vertical]) {
                    if diff.isEmpty {
                        Text(
                            "No textual diff is available for this file."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                    } else {
                        LazyVStack(
                            alignment: .leading,
                            spacing: 0
                        ) {
                            ForEach(
                                Array(
                                    diff
                                        .components(separatedBy: .newlines)
                                        .enumerated()
                                ),
                                id: \.offset
                            ) { _, line in
                                RemoteGitDiffLine(line: line)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .textSelection(.enabled)
                .privacySensitive()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn’t Load Diff",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading diff…")
            }
        }
        .navigationTitle(entry.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if staged {
                        Button("Unstage", systemImage: "minus") {
                            Task {
                                if await project.unstage(entry) {
                                    dismiss()
                                }
                            }
                        }
                    } else {
                        Button("Stage", systemImage: "plus") {
                            Task {
                                if await project.stage(entry) {
                                    dismiss()
                                }
                            }
                        }
                        Button(
                            "Discard Changes…",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            confirmDiscard = true
                        }
                    }
                } label: {
                    Label("File actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            entry.isUntracked
                ? "Delete \(entry.fileName)?"
                : "Discard changes in \(entry.fileName)?",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                Task {
                    if await project.discard(entry) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                entry.isUntracked
                    ? "This permanently deletes the untracked file from "
                        + "the remote host."
                    : "This restores the remote file to its Git version."
            )
        }
        .task(id: "\(entry.path)-\(staged)") {
            do {
                diff = try await project.loadDiff(
                    for: entry,
                    staged: staged
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct RemoteGitDiffLine: View {
    let line: String

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .fixedSize(horizontal: true, vertical: false)
            .background(background)
    }

    private var foreground: Color {
        if line.hasPrefix("@@") {
            return .blue
        }
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return .green
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return .red
        }
        if line.hasPrefix("diff ")
            || line.hasPrefix("index ")
            || line.hasPrefix("+++")
            || line.hasPrefix("---") {
            return .secondary
        }
        return .primary
    }

    private var background: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return .green.opacity(0.10)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return .red.opacity(0.10)
        }
        if line.hasPrefix("@@") {
            return .blue.opacity(0.08)
        }
        return .clear
    }
}

private struct RemoteGitBranchesView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var project: RemoteProjectModel
    @State private var newBranchName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Create Branch") {
                    HStack {
                        TextField(
                            "New branch name",
                            text: $newBranchName
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("git-new-branch-name")

                        Button("Create") {
                            createBranch()
                        }
                        .disabled(
                            newBranchName
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                .isEmpty
                                || project.isRunningGitAction
                        )
                    }
                }

                Section("Branches") {
                    ForEach(
                        project.git?.branches ?? [],
                        id: \.self
                    ) { branch in
                        Button {
                            Task {
                                if await project.switchBranch(to: branch) {
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack {
                                Label(
                                    branch,
                                    systemImage: "arrow.triangle.branch"
                                )
                                Spacer()
                                if branch == project.git?.branch {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            branch == project.git?.branch
                                || project.isRunningGitAction
                        )
                    }
                }

                if let git = project.git,
                   git.upstream == nil,
                   !git.remotes.isEmpty {
                    Section("Publish Current Branch") {
                        ForEach(git.remotes, id: \.self) { remote in
                            Button {
                                Task {
                                    if await project.push(to: remote) {
                                        dismiss()
                                    }
                                }
                            } label: {
                                Label(
                                    "Publish to \(remote)",
                                    systemImage: "icloud.and.arrow.up"
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if project.isRunningGitAction {
                    ProgressView()
                        .padding()
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
            }
        }
    }

    private func createBranch() {
        let name = newBranchName
        Task {
            if await project.createBranch(named: name) {
                newBranchName = ""
                dismiss()
            }
        }
    }
}

private struct RemoteGitOperationView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var project: RemoteProjectModel

    var body: some View {
        NavigationStack {
            Group {
                if let operation = project.gitOperation {
                    VStack(alignment: .leading, spacing: 16) {
                        Label {
                            Text(operation.statusText)
                                .font(.headline)
                        } icon: {
                            switch operation.state {
                            case .running:
                                ProgressView()
                            case .succeeded:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .failed:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }

                        ScrollView([.horizontal, .vertical]) {
                            Text(
                                operation.output.isEmpty
                                    ? "Waiting for the remote Git command…"
                                    : operation.output
                            )
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .topLeading
                            )
                        }
                        .privacySensitive()
                    }
                    .padding()
                } else {
                    ContentUnavailableView(
                        "No Git Operation",
                        systemImage: "terminal"
                    )
                }
            }
            .navigationTitle("Git Output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        project.dismissGitOperation()
                        dismiss()
                    }
                    .disabled(project.gitOperation?.isRunning == true)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct RemoteGitCommitRow: View {
    let commit: RemoteGitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(commit.subject)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(commit.shortHash)
                    .font(.system(.caption, design: .monospaced))
                Text(commit.author)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(commit.relativeDate)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct RemoteGitCommitView: View {
    @ObservedObject var project: RemoteProjectModel
    let commit: RemoteGitCommit

    @State private var contents: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let contents {
                ScrollView([.horizontal, .vertical]) {
                    Text(contents)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                        .padding()
                }
                .privacySensitive()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn’t Load Commit",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading commit…")
            }
        }
        .navigationTitle(commit.shortHash)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy Commit Hash", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = commit.hash
                }
            }
        }
        .task {
            do {
                contents = try await project.loadCommit(commit)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
