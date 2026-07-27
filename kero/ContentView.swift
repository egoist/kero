//
//  ContentView.swift
//  kero
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var tabSwitcher = TabSwitcherController()

    var body: some View {
        HStack(spacing: 0) {
            if manager.isLeftSidebarVisible {
                SidebarView(manager: manager)
            }

            VStack(spacing: 0) {
                // Above the pane stack so header tooltips, which hang down
                // into the terminal area, aren't covered by it.
                MainHeaderView(manager: manager)
                    .zIndex(1)

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

            // Dropping the hidden sidebar also drops any expanded file tree,
            // git snapshot and process snapshot it owned instead of retaining
            // them for the rest of the window's lifetime.
            if manager.isPanelVisible {
                RightSidebarView(manager: manager)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            TerminalParkingView(sessions: parkedTerminalSessions)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if manager.isCommandPaletteVisible {
                CommandPaletteView(manager: manager)
            }
        }
        .overlay {
            if tabSwitcher.isPresented, let project = manager.selectedProject {
                TabSwitcherOverlay(project: project, controller: tabSwitcher)
                    .zIndex(10)
            }
        }
        .background {
            TabSwitcherEventMonitor(manager: manager, controller: tabSwitcher)
                .frame(width: 0, height: 0)
        }
        .background(WindowChromeAccessor { manager.attach(to: $0) })
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
    }

    /// Sessions in the visible tab are owned by `TerminalHostView`; every
    /// other session stays window-attached in the invisible parking host.
    private var parkedTerminalSessions: [TerminalSession] {
        let visibleIDs = Set(
            manager.selectedProject?.selectedTab?.sessions.map(\.id) ?? []
        )
        return manager.projects
            .flatMap(\.sessions)
            .filter { !visibleIDs.contains($0.id) }
    }

    /// The pane layer paints an opaque background to hide unselected diffs in
    /// its gaps — but a diff tab's own pane must stay clear so its web view
    /// (mounted in the stack behind) shows through.
    private var paneLayerIsOpaque: Bool {
        guard let tab = manager.selectedProject?.selectedTab else { return true }
        return tab.diffs.isEmpty
    }

    @ViewBuilder
    private var emptyState: some View {
        if manager.selectedProject == nil {
            emptyStatePrompt(
                title: "No open projects",
                buttonTitle: "New Project  ⌘N",
                action: { manager.newProject() }
            )
        } else {
            // A project whose tabs were all closed stays open; offer to reopen
            // a session rather than showing the no-projects prompt.
            emptyStatePrompt(
                title: "No open sessions",
                buttonTitle: "New Session  ⌘T",
                action: { manager.newSession() }
            )
        }
    }

    private func emptyStatePrompt(
        title: String, buttonTitle: String, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
        }
    }
}

/// Slim bar above the terminal: the selected project's sessions as
/// horizontal tabs on the left, sidebar toggle on the right. Doubles as
/// window-drag space.
private struct MainHeaderView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes

    /// With the left sidebar hidden the header slides under the window's
    /// traffic-light buttons, so inset its content to clear them.
    private var leadingInset: CGFloat {
        manager.isLeftSidebarVisible ? 8 : 78
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                if let project = manager.selectedProject {
                    // Everything in the header that isn't the scrollable tab
                    // strip: leading inset + trailing padding (8), HStack
                    // spacings (16), sidebar toggle (24), "+" and spacing (26),
                    // and the exit-zoom button (24 + 8 spacing) while shown.
                    SessionTabsView(
                        project: project,
                        maxStripWidth: max(0, geo.size.width - leadingInset - 74 - (manager.isPaneZoomed ? 32 : 0))
                    )
                }
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                // Zoom indicator: only visible while the selected tab has a
                // zoomed pane. Styled like the sidebar toggle next to it, with
                // the accent tint marking the active state. Click restores the
                // layout.
                if manager.isPaneZoomed {
                    Button {
                        manager.togglePaneZoom()
                    } label: {
                        Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: Theme.accent))
                            .frame(width: 24, height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .tooltip("Exit Pane Zoom (⇧⌘↩)", edge: .below, alignment: .trailing)
                }
                // No project means the sidebar has nothing to show, so drop
                // its toggle too — matching the panel collapsing itself.
                if manager.selectedProject != nil {
                    Button {
                        manager.toggleSidebar()
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(manager.isPanelVisible ? Color(nsColor: Theme.accent) : .secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .tooltip("Toggle Right Sidebar (⇧⌘B)", edge: .below, alignment: .trailing)
                }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, 8)
            .frame(height: geo.size.height)
        }
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
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
    @State private var draggedTabID: UUID?
    @State private var tabFrames: [UUID: CGRect] = [:]
    /// Tab currently showing the inline rename field, if any.
    @State private var renamingTabID: UUID?

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
                            close: { project.close(tab) },
                            renamingTabID: $renamingTabID
                        )
                        .contextMenu { tabContextMenu(for: tab) }
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TabFramePreferenceKey.self,
                                    value: [tab.id: proxy.frame(in: .global)]
                                )
                            }
                        }
                        .opacity(draggedTabID == tab.id ? 0.65 : 1)
                        // Masked to .subviews while renaming so dragging in the
                        // text field selects text instead of reordering the tab.
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { value in
                                    updateTabDrag(source: tab.id, location: value.location)
                                }
                                .onEnded { _ in endTabDrag() },
                            including: renamingTabID == tab.id ? .subviews : .all
                        )
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
            .tooltip("New Session (⌘T)", edge: .below)
        }
        .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
    }

    /// Reorders immediately as the pointer crosses another tab. This direct
    /// gesture deliberately avoids a pasteboard drag session, which the
    /// hidden title bar can otherwise claim as a window move first.
    private func updateTabDrag(source: UUID, location: CGPoint) {
        draggedTabID = source
        NSCursor.closedHand.set()
        guard let target = tabFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            project.moveTab(source, to: target)
        }
    }

    private func endTabDrag() {
        draggedTabID = nil
        NSCursor.arrow.set()
    }

    @ViewBuilder
    private func tabContextMenu(for tab: PaneTab) -> some View {
        Button("Rename…") { renamingTabID = tab.id }
        if tab.customName != nil {
            Button("Use Automatic Title") { tab.customName = nil }
        }
        Divider()
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

/// Collects each tab's global frame so a direct drag gesture can hit-test the
/// pointer even while the horizontal strip is moving under it.
private struct TabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
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
    @Binding var renamingTabID: UUID?

    var body: some View {
        let paneCount = tab.allPanes.count
        if renamingTabID == tab.id {
            TabRenameChrome(
                systemImage: tab.focusedContent?.systemImage ?? "terminal",
                initialValue: tab.displayTitle ?? "",
                commit: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    tab.customName = trimmed.isEmpty ? nil : trimmed
                },
                end: { renamingTabID = nil }
            )
        } else {
            switch tab.focusedContent {
            case .session(let session):
                SessionTabLabel(session: session, customTitle: tab.customName, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
            case .file(let file):
                FileTabLabel(file: file, customTitle: tab.customName, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
            case .diff(let diff):
                TabItemChrome(
                    systemImage: "plus.forwardslash.minus",
                    title: tab.customName ?? diff.title,
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
}

/// Inline editor shown in place of a tab while it's renamed — the same
/// affordance as the project row's rename. Commits on Return or focus loss,
/// cancels on Escape; an empty name returns the tab to its automatic title.
private struct TabRenameChrome: View {
    @ObservedObject private var themeChanges = Theme.changes
    let systemImage: String
    let commit: (String) -> Void
    let end: () -> Void

    @State private var draft: String
    /// Set by the first commit/cancel so the focus-loss handler that fires
    /// while the field is being torn down doesn't commit a second time.
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        systemImage: String,
        initialValue: String,
        commit: @escaping (String) -> Void,
        end: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.commit = commit
        self.end = end
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.accent))
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .frame(width: 110)
                .focused($focused)
                .onSubmit { finish(apply: true) }
                .onExitCommand { finish(apply: false) }
                .onChange(of: focused) {
                    if !focused { finish(apply: true) }
                }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.09))
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    private func finish(apply: Bool) {
        guard !finished else { return }
        finished = true
        if apply { commit(draft) }
        end()
    }
}

private struct SessionTabLabel: View {
    @ObservedObject var session: TerminalSession
    /// User-assigned tab name overriding the live terminal title.
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "terminal",
            title: customTitle ?? session.title,
            paneCount: paneCount,
            isSelected: isSelected,
            select: select,
            close: close
        )
    }
}

private struct FileTabLabel: View {
    @ObservedObject var file: FileTab
    /// User-assigned tab name overriding the file name.
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "doc.text",
            title: customTitle ?? file.name,
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
    @ObservedObject private var themeChanges = Theme.changes
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
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.accent)) : AnyShapeStyle(.tertiary))
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
        // Cap tab width so a long title truncates instead of stretching the
        // tab; short titles still shrink to fit (maxWidth is an upper bound).
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
    }
}
