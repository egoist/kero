//
//  SidebarView.swift
//  kero
//

import SwiftUI

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    @AppStorage("leftSidebarWidth") private var width: Double = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header-height strip housing the traffic-light buttons.
            WindowDragArea()
                .frame(height: 38)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(manager.projects.enumerated()), id: \.element.id) { index, project in
                        SidebarProjectRow(
                            project: project,
                            index: index,
                            isSelected: project.id == manager.selectedProjectID,
                            select: { manager.selectedProjectID = project.id },
                            close: { manager.close(project) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Spacer(minLength: 8)

            Button {
                manager.newProject()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New Project")
                        .font(.system(size: 12))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: width)
        .background(VisualEffectView(material: .sidebar))
        .overlay(alignment: .trailing) {
            SidebarResizeHandle(
                edge: .trailing,
                width: $width,
                range: 160...400,
                defaultWidth: 220
            )
        }
    }
}

private struct SidebarProjectRow: View {
    @ObservedObject var project: Project
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        Group {
            if isRenaming {
                rowContent
            } else {
                Button(action: select) {
                    rowContent
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…") {
                beginRename()
            }
            if project.customName != nil {
                Button("Use Automatic Title") {
                    project.customName = nil
                }
            }
            Divider()
            Button("Close Project") {
                close()
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: Theme.cursor) : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: renameFocused) {
                            if !renameFocused, isRenaming {
                                commitRename()
                            }
                        }
                } else {
                    Text(project.name)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
                subtitle
            }

            Spacer(minLength: 0)

            if isHovering, !isRenaming {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if index < 9, !isRenaming {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func beginRename() {
        renameDraft = project.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        project.customName = trimmed.isEmpty ? nil : trimmed
        isRenaming = false
    }

    @ViewBuilder
    private var subtitle: some View {
        if project.sessions.count > 1 {
            Text("\(project.sessions.count) sessions")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let session = project.selectedSession {
            SessionDirectoryLabel(session: session)
        }
    }
}

/// Small subtitle showing a session's current directory; separate view so
/// it observes the session's own published working directory.
private struct SessionDirectoryLabel: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let dir = session.directoryLabel {
            Text(dir)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
