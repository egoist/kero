//
//  CommandPaletteView.swift
//  mitty
//

import SwiftUI

/// One executable entry in the ⌘K palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    let action: () -> Void
}

/// Centered ⌘K overlay: fuzzy-searchable list of app actions. Arrow keys
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
            Color.black.opacity(0.15)
                .onTapGesture { dismiss() }

            panel
                .padding(.top, 110)
        }
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        var items: [PaletteCommand] = [
            PaletteCommand(id: "new-session", title: "New Session", systemImage: "terminal", shortcut: "⌘T") {
                manager.newSession()
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
            PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", systemImage: "sidebar.right", shortcut: "⇧⌘B") {
                manager.toggleSidebar()
            },
            PaletteCommand(id: "toggle-files", title: "Toggle Files Panel", systemImage: "doc.text", shortcut: "⇧⌘E") {
                manager.togglePanel(.files)
            },
            PaletteCommand(id: "toggle-git", title: "Toggle Git Panel", systemImage: "arrow.triangle.branch", shortcut: "⇧⌘G") {
                manager.togglePanel(.git)
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

    private var filtered: [PaletteCommand] {
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return commands }
        return commands
            .compactMap { command in
                fuzzyScore(command.title, pattern).map { (command, $0) }
            }
            .sorted { $0.1 > $1.1 }
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
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onSubmit { runSelected() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()
                .opacity(0.5)

            if filtered.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                                row(command, index: index)
                                    .id(command.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 322)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) {
                        if filtered.indices.contains(selection) {
                            proxy.scrollTo(filtered[selection].id)
                        }
                    }
                }
            }
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
            searchFocused = true
        }
        .onChange(of: query) {
            selection = 0
        }
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
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
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
        manager.isCommandPaletteVisible = false
    }
}
