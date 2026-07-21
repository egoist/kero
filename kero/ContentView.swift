//
//  ContentView.swift
//  kero
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(manager: manager)

            VStack(spacing: 0) {
                MainHeaderView(manager: manager)

                ZStack {
                    // Diff panes stay mounted while unselected: removing one
                    // would pull its NSHostingView out of the window, which
                    // tears down and re-creates the WKWebView inside (losing
                    // the rendered diff and scroll position). Unselected ones
                    // just sit covered by the active tab's opaque pane layer.
                    // Diffs are always their own single-pane tab, so a selected
                    // diff fills the whole content area, unchanged.
                    if let project = manager.selectedProject {
                        ForEach(project.diffPlacements, id: \.diff.id) { placement in
                            DiffViewerView(
                                diff: placement.diff,
                                isSelected: project.selectedTabID == placement.tabID
                            )
                            .background(Color(nsColor: Theme.background))
                            .allowsHitTesting(project.selectedTabID == placement.tabID)
                            .zIndex(project.selectedTabID == placement.tabID ? 1 : 0)
                        }
                    }
                    Group {
                        if let tab = manager.selectedProject?.selectedTab {
                            PaneLayoutView(tab: tab, onSplit: { manager.split(toward: $0) })
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Opaque so the pane gaps hide the unselected diffs behind,
                    // except while a diff tab is up — then stay clear so its
                    // web view shows through from the stack below.
                    .background(paneLayerIsOpaque ? AnyShapeStyle(Color(nsColor: Theme.background)) : AnyShapeStyle(Color.clear))
                    .zIndex(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: Theme.background))

            RightSidebarView(manager: manager)
        }
        .ignoresSafeArea()
        .overlay {
            if manager.isCommandPaletteVisible {
                CommandPaletteView(manager: manager)
            }
        }
        .background(WindowChromeAccessor())
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
    }

    /// The pane layer paints an opaque background to hide unselected diffs in
    /// its gaps — but a diff tab's own pane must stay clear so its web view
    /// (mounted in the stack behind) shows through.
    private var paneLayerIsOpaque: Bool {
        guard let tab = manager.selectedProject?.selectedTab else { return true }
        return tab.diffs.isEmpty
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No open projects")
                .foregroundStyle(.secondary)
            Button("New Project  ⌘N") {
                manager.newProject()
            }
        }
    }
}

/// Slim bar above the terminal: the selected project's sessions as
/// horizontal tabs on the left, sidebar toggle on the right. Doubles as
/// window-drag space.
private struct MainHeaderView: View {
    @ObservedObject var manager: TerminalManager

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                if let project = manager.selectedProject {
                    // Everything in the header that isn't the scrollable tab
                    // strip: paddings (16), HStack spacings (16), sidebar
                    // toggle (24), "+" button and its spacing (26).
                    SessionTabsView(project: project, maxStripWidth: max(0, geo.size.width - 82))
                }
                Spacer(minLength: 0)
                // No project means the sidebar has nothing to show, so drop
                // its toggle too — matching the panel collapsing itself.
                if manager.selectedProject != nil {
                    Button {
                        manager.toggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(manager.isPanelVisible ? Color(nsColor: Theme.cursor) : .secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Sidebar (⇧⌘B)")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: geo.size.height)
        }
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }
}

/// Horizontal tabs for one project — terminal sessions and open files —
/// plus a "+" button.
private struct SessionTabsView: View {
    @ObservedObject var project: Project
    let maxStripWidth: CGFloat
    @State private var overflow = StripOverflow()

    /// Which edges have off-screen tabs, i.e. where to show a fade hint.
    private struct StripOverflow: Equatable {
        var left = false
        var right = false
    }

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(project.tabs) { tab in
                        PaneTabItem(
                            tab: tab,
                            isSelected: tab.id == project.selectedTabID,
                            select: { project.selectedTabID = tab.id },
                            close: { project.close(tab) }
                        )
                        .contextMenu { tabContextMenu(for: tab) }
                    }
                }
            }
            .onScrollGeometryChange(for: StripOverflow.self) { geo in
                StripOverflow(
                    left: geo.contentOffset.x > 0.5,
                    right: geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width - 0.5
                )
            } action: { _, new in
                overflow = new
            }
            // Keep the active tab visible: scrolls the minimum distance to
            // reveal it (anchor: nil is a no-op when it's already fully in view).
            .onChange(of: project.selectedTabID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id)
                }
            }
            .onAppear {
                // Restored sessions may open with an off-screen active tab.
                guard let id = project.selectedTabID else { return }
                DispatchQueue.main.async { proxy.scrollTo(id) }
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [overflow.left ? .clear : .black, .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 20)
                    Color.black
                    LinearGradient(
                        colors: [.black, overflow.right ? .clear : .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 20)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: overflow)
            .frame(maxWidth: maxStripWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                project.newSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("New Session (⌘T)")
        }
    }

    @ViewBuilder
    private func tabContextMenu(for tab: PaneTab) -> some View {
        if case .file(let file) = tab.focusedContent {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            Button("Copy Absolute Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Divider()
        }
        Button("Close") { project.close(tab) }
        Button("Close Others") { project.closeOthers(tab) }
            .disabled(project.tabs.count <= 1)
        Button("Close Tabs to the Right") { project.closeToRight(of: tab) }
            .disabled(project.tabs.last?.id == tab.id)
        Divider()
        Button("Close All") { project.closeAll() }
    }
}

/// A tab in the strip. Shows the focused pane's title/icon, with a small
/// counter when the tab holds more than one pane. Observes the tab so focus
/// and layout changes refresh it; the focused content is observed by the
/// per-kind label below so its live title/dirty state shows.
private struct PaneTabItem: View {
    @ObservedObject var tab: PaneTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        let paneCount = tab.allPanes.count
        switch tab.focusedContent {
        case .session(let session):
            SessionTabLabel(session: session, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
        case .file(let file):
            FileTabLabel(file: file, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
        case .diff(let diff):
            TabItemChrome(
                systemImage: "plus.forwardslash.minus",
                title: diff.title,
                paneCount: paneCount,
                isSelected: isSelected,
                select: select,
                close: close
            )
            .help(diff.path)
        case nil:
            EmptyView()
        }
    }
}

private struct SessionTabLabel: View {
    @ObservedObject var session: TerminalSession
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "terminal",
            title: session.title,
            paneCount: paneCount,
            isSelected: isSelected,
            select: select,
            close: close
        )
    }
}

private struct FileTabLabel: View {
    @ObservedObject var file: FileTab
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "doc.text",
            title: file.name,
            paneCount: paneCount,
            isSelected: isSelected,
            isDirty: file.isDirty,
            select: select,
            close: close
        )
        .help(file.path)
    }
}

private struct TabItemChrome: View {
    let systemImage: String
    let title: String
    var paneCount: Int = 1
    let isSelected: Bool
    var isDirty = false
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.cursor)) : AnyShapeStyle(.tertiary))
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                if paneCount > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 7.5, weight: .semibold))
                        Text("\(paneCount)")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.tertiary)
                }
                if isHovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if isDirty {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .frame(width: 14, height: 14)
                } else {
                    Spacer()
                        .frame(width: 14)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
    }
}
