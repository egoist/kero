//
//  SidebarView.swift
//  kero
//

import AppKit
import SwiftUI

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("leftSidebarWidth") private var width: Double = 220
    @State private var draggedProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header-height strip housing the traffic-light buttons and the
            // control for collapsing this sidebar.
            HStack(spacing: 0) {
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                ChromeIconButton(
                    systemImage: "sidebar.left",
                    tooltip: "Toggle Left Sidebar (⌘B)"
                ) {
                    manager.toggleLeftSidebar()
                }
            }
            .padding(.trailing, 8)
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
                            onDragEnded: endProjectDrag,
                            fontSize: settings.sidebarFontSize
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
                    .fill(Color(nsColor: Theme.divider))
                    .frame(height: 1)
            }
        }
        .frame(width: width)
        .background {
            // Kero's built-in Default themes keep the native translucent
            // sidebar material; every other theme — including the GitHub
            // originals they're based on — paints its flat sidebar shade so
            // the strip follows the palette.
            if Theme.isDefault(dark: colorScheme == .dark) {
                VisualEffectView(material: .sidebar)
            } else {
                Color(nsColor: Theme.sidebar)
            }
        }
        // Hairline between sidebar and content: themes fill both with the
        // same background, so the boundary needs its own line. The built-in
        // Defaults keep their material fill, whose contrast already draws
        // the edge.
        .overlay(alignment: .trailing) {
            if !Theme.isDefault(dark: colorScheme == .dark) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
        }
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

struct ChromeIconButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    var font: Font = .system(size: 12, weight: .medium)
    var iconSize: CGFloat = 16
    var tooltipEdge: TooltipEdge = .below
    var tooltipAlignment: HorizontalAlignment = .trailing
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, edge: tooltipEdge, alignment: tooltipAlignment)
    }
}

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    var body: some View {
        ChromeIconButton(
            systemImage: systemImage,
            tooltip: tooltip,
            tooltipEdge: .above,
            tooltipAlignment: tooltipAlignment,
            action: action
        )
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
    @ObservedObject private var themeChanges = Theme.changes
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let fontSize: Double

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
            Button("Set Project Directory…") {
                pickProjectDirectory()
            }
            if project.customDirectory != nil {
                Button("Use Automatic Directory") {
                    project.customDirectory = nil
                }
            }
            Divider()
            Button("Close Project") {
                close()
            }
        }
    }

    /// Lets the user pin the project's directory — the root the file tree
    /// and git panels anchor to instead of the automatic closest-git-repo.
    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button in the project directory picker.")
        panel.message = String(
            localized: "Choose the directory for “\(project.name)”.",
            comment: "Message in the project directory picker. The placeholder is a project name."
        )
        if let current = project.customDirectory
            ?? project.selectedSession?.currentDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            project.customDirectory = url.path
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: Theme.accent) : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize, weight: .medium))
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
                        .font(.system(size: fontSize))
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
                Text(verbatim: "⌘\(index + 1)")
                    .font(.system(size: supportingFontSize))
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
                .font(.system(size: supportingFontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let session = project.selectedSession {
            SessionDirectoryLabel(session: session, fontSize: supportingFontSize)
        }
    }

    private var supportingFontSize: Double {
        max(fontSize - 2, AppSettings.sidebarFontSizeRange.lowerBound - 1)
    }
}

/// Small subtitle showing a session's current directory; separate view so
/// it observes the session's own published working directory.
private struct SessionDirectoryLabel: View {
    @ObservedObject var session: TerminalSession
    let fontSize: Double

    var body: some View {
        if let dir = session.directoryLabel {
            Text(dir)
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
