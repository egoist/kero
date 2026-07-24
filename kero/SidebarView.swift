//
//  SidebarView.swift
//  kero
//

import SwiftUI

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    @Environment(\.openSettings) private var openSettings
    @AppStorage("leftSidebarWidth") private var width: Double = 220
    @State private var draggedProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]

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
                            close: { manager.close(project) },
                            isDragging: draggedProjectID == project.id,
                            onDrag: { updateProjectDrag(source: project.id, location: $0) },
                            onDragEnded: endProjectDrag
                        )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProjectFramePreferenceKey.self,
                                    value: [project.id: proxy.frame(in: .global)]
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            HStack(spacing: 2) {
                SidebarFooterButton(
                    systemImage: "plus",
                    tooltip: "New Project (⌘N)"
                ) { manager.newProject() }
                Spacer()
                SidebarFooterButton(
                    systemImage: "exclamationmark.bubble",
                    tooltip: "Send Feedback",
                    tooltipAlignment: .trailing
                ) {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/egoist/kero/issues/new")!
                    )
                }
                SidebarFooterButton(
                    systemImage: "gearshape",
                    tooltip: "Settings (⌘,)",
                    tooltipAlignment: .trailing
                ) { openSettings() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
            }
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
        .onPreferenceChange(ProjectFramePreferenceKey.self) { projectFrames = $0 }
    }

    private func updateProjectDrag(source: UUID, location: CGPoint) {
        draggedProjectID = source
        NSCursor.closedHand.set()
        guard let target = projectFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            manager.moveProject(source, to: target)
        }
    }

    private func endProjectDrag() {
        draggedProjectID = nil
        NSCursor.arrow.set()
    }
}

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: String
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, alignment: tooltipAlignment)
    }
}

private struct ProjectFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SidebarProjectRow: View {
    @ObservedObject var project: Project
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void

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
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { onDrag($0.location) }
                        .onEnded { _ in onDragEnded() }
                )
            }
        }
        .opacity(isDragging ? 0.65 : 1)
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
                HStack(spacing: 3) {
                    if let activity = project.activityIndicator {
                        Text(activity)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .accessibilityHidden(true)
                    }
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
        renameDraft = project.renameDraftName
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        project.customName = Project.normalizedCustomName(renameDraft)
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
