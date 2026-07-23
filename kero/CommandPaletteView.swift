//
//  CommandPaletteView.swift
//  kero
//

import SwiftUI

/// Groups palette rows under a header — built-in actions vs. open sessions.
enum PaletteSection: Hashable {
    case command
    case session

    var title: String {
        switch self {
        case .command: return "Commands"
        case .session: return "Sessions"
        }
    }

    /// Sections render in this order regardless of match score.
    var order: Int {
        switch self {
        case .command: return 0
        case .session: return 1
        }
    }
}

/// One selectable entry in the ⌘P palette: a built-in action, or a jump to an
/// open terminal session.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// Secondary text shown after the title — a session's working directory.
    var subtitle: String? = nil
    var shortcut: String? = nil
    var section: PaletteSection = .command
    /// Text the fuzzy filter matches against; defaults to `title`, widened for
    /// sessions to also cover the project name and directory.
    var searchText: String? = nil
    let action: () -> Void
}

/// Centered ⌘P overlay: fuzzy-searchable list of app actions. Arrow keys
/// move the selection, Return runs it, Escape (or clicking the backdrop)
/// dismisses.
struct CommandPaletteView: View {
    @ObservedObject var manager: TerminalManager
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

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
        .onExitCommand { dismissFromKeyboard() }
        .onDisappear { manager.restoreFocusAfterCommandPalette() }
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        var items: [PaletteCommand] = [
            PaletteCommand(id: "new-session", title: "New Session", systemImage: "terminal", shortcut: "⌘T") {
                manager.newSession()
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
            PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", systemImage: "sidebar.right", shortcut: "⇧⌘B") {
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
                    title: session.title,
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

    private var filtered: [PaletteCommand] {
        let pattern = query.trimmingCharacters(in: .whitespaces)
        let all = commands + sessionCommands
        guard !pattern.isEmpty else { return all }
        // Rank by match score within each section, but keep the sections in
        // their fixed order (commands first) so the layout stays stable as the
        // query changes.
        return all
            .compactMap { command in
                fuzzyScore(command.searchText ?? command.title, pattern).map { (command, $0) }
            }
            .sorted { lhs, rhs in
                lhs.0.section.order != rhs.0.section.order
                    ? lhs.0.section.order < rhs.0.section.order
                    : lhs.1 > rhs.1
            }
            .map(\.0)
    }

    /// Case-insensitive subsequence match. Word-boundary hits and runs of
    /// consecutive matches score higher; nil means no match.
    private func fuzzyScore(_ candidate: String, _ pattern: String) -> Int? {
        let chars = Array(candidate.lowercased())
        var score = 0
        var index = 0
        var lastMatch = -1
        for ch in pattern.lowercased() {
            var found = false
            while index < chars.count {
                if chars[index] == ch {
                    if index == 0 || chars[index - 1] == " " {
                        score += 10
                    } else if index == lastMatch + 1 {
                        score += 5
                    } else {
                        score += 1
                    }
                    lastMatch = index
                    index += 1
                    found = true
                    break
                }
                index += 1
            }
            if !found { return nil }
        }
        return score
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search commands and sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismissFromKeyboard(); return .handled }
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
            // Defer to the next runloop tick: assigning focus synchronously
            // inside the appearance pass can be dropped before the field
            // editor is ready, which left the palette opening unfocused.
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: query) {
            selection = 0
        }
    }

    /// Result list, computing `filtered` once per render. Section headers only
    /// appear when both commands and sessions are present, so a query that
    /// matches only one kind reads as a plain list.
    @ViewBuilder
    private var results: some View {
        let items = filtered
        if items.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            let showHeaders = items.contains { $0.section == .command }
                && items.contains { $0.section == .session }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                            if showHeaders,
                               index == 0 || items[index - 1].section != command.section {
                                sectionHeader(command.section, isFirst: index == 0)
                            }
                            row(command, index: index)
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

    private func row(_ command: PaletteCommand, index: Int) -> some View {
        let isSelected = index == selection
        return Button {
            run(command)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.cursor)) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(command.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
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
        .onHover { hovering in
            if hovering { selection = index }
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

    /// Escape reaches us as AppKit's `cancelOperation:`, which SwiftUI can
    /// dispatch inside a view-update pass — flipping the manager's published
    /// `isCommandPaletteVisible` there logs "Publishing changes from within
    /// view updates". Hop to the next runloop so the removal lands cleanly.
    /// (Return and backdrop taps arrive during normal event handling and can
    /// dismiss synchronously.)
    private func dismissFromKeyboard() {
        DispatchQueue.main.async { dismiss() }
    }
}
