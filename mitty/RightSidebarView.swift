//
//  RightSidebarView.swift
//  mitty
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

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
                        FileTreePanel(model: fileTree, session: manager.selectedSession)
                    case .git:
                        GitPanel(model: git, session: manager.selectedSession)
                    }
                }
                .frame(width: 240)
                .background(Color(nsColor: Theme.sidebar))
            }
        }
        .onAppear(perform: syncModels)
        .onReceive(refreshTimer) { _ in syncModels() }
        .onChange(of: manager.isPanelVisible) { syncModels() }
        .onChange(of: manager.panelTab) { syncModels() }
        .onChange(of: manager.selectedSession?.id) { syncModels() }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
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
                        FileTreeRow(model: model, item: item, session: session)
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

    @State private var isHovering = false

    var body: some View {
        Button {
            if item.isDirectory {
                model.toggle(item)
            }
        } label: {
            HStack(spacing: 5) {
                if item.isDirectory {
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
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") {
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
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !item.isDirectory {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                }
            }
        )
    }
}

// MARK: - Git panel

private struct GitPanel: View {
    @ObservedObject var model: GitStatusModel
    let session: TerminalSession?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.cursor))
                PanelHeader(
                    title: model.isRepo ? (model.branch ?? "…") : "Git",
                    subtitle: model.rootPath
                )
                if model.ahead > 0 {
                    badge("↑\(model.ahead)")
                }
                if model.behind > 0 {
                    badge("↓\(model.behind)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if !model.isRepo {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("Not a git repository")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else if model.stagedEntries.isEmpty && model.changedEntries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("Working tree clean")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !model.stagedEntries.isEmpty {
                            sectionLabel("STAGED")
                            ForEach(model.stagedEntries) { entry in
                                GitEntryRow(entry: entry, status: entry.staged)
                            }
                        }
                        if !model.changedEntries.isEmpty {
                            sectionLabel("CHANGES")
                            ForEach(model.changedEntries) { entry in
                                GitEntryRow(entry: entry, status: entry.unstaged)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }
}

private struct GitEntryRow: View {
    let entry: GitStatusModel.Entry
    let status: Character

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text(String(status))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Text(entry.fileName)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(entry.directory)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
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

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
