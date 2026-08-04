//
//  ContentView.swift
//  kero
//

import SwiftUI

enum BottomToolbarLayout {
    static let idealHeight: CGFloat = 32

    static func height(for session: TerminalSession?) -> CGFloat {
        guard session?.backend == .libghostty,
              let cellHeight = session?.terminalCellSize?.height,
              cellHeight.isFinite, cellHeight > 0 else {
            return idealHeight
        }
        let rowCount = max(1, (idealHeight / cellHeight).rounded())
        return rowCount * cellHeight
    }
}

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var tabSwitcher = TabSwitcherController()
    @StateObject private var git = GitStatusModel()

    /// Every terminal in the selected project can change the same repository.
    /// Watching command completion keeps the toolbar current without polling.
    private var commandCompletionSequences: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues:
            manager.selectedProject?.sessions.map {
                ($0.id, $0.commandLifecycle.completionSequence)
            } ?? []
        )
    }

    private var bottomToolbarHeight: CGFloat {
        BottomToolbarLayout.height(for: manager.selectedSession)
    }

    var body: some View {
        HStack(spacing: 0) {
            if manager.isLeftSidebarVisible {
                SidebarView(
                    manager: manager,
                    bottomBarHeight: bottomToolbarHeight
                )
            }

            VStack(spacing: 0) {
                // Above the pane stack so header tooltips, which hang down
                // into the terminal area, aren't covered by it.
                MainHeaderView(manager: manager)
                    .zIndex(1)

                ZStack {
                    // Diff panes stay mounted after their project has been
                    // visited: removing a project's stack pulls every
                    // NSHostingView out of the window at once, making project
                    // switching block while WebKit tears down and reattaches
                    // the rendered diffs. Unvisited restored projects remain
                    // lazy; inactive stacks sit beneath the active opaque pane.
                    ForEach(manager.projectsWithMountedDiffs) { project in
                        ForEach(project.diffPlacements, id: \.diff.id) { placement in
                            let isSelected = manager.selectedProjectID == project.id
                                && project.selectedTabID == placement.tabID
                            DiffViewerView(
                                diff: placement.diff,
                                isSelected: isSelected
                            )
                            .background(Color(nsColor: Theme.background))
                            .allowsHitTesting(isSelected)
                            .zIndex(isSelected ? 1 : 0)
                        }
                    }
                    Group {
                        if let tab = manager.selectedProject?.selectedTab {
                            PaneLayoutView(
                                tab: tab,
                                onSplit: { manager.split(toward: $0) },
                                onNewBrowserTab: {
                                    manager.newBrowserTab(initialURL: $0)
                                },
                                onNewBrowserPane: {
                                    manager.newBrowserPane(initialURL: $0)
                                }
                            )
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

                if manager.selectedProject != nil
                    && settings.toolbarVisibility != .hide
                    && (git.isRepo || settings.toolbarVisibility == .always) {
                    BottomToolbarView(
                        model: git,
                        height: bottomToolbarHeight,
                        toggleGitPanel: { manager.togglePanel(.git) },
                        hideToolbar: { settings.toolbarVisibility = .hide }
                    )
                }
            }
            .background(Color(nsColor: Theme.background))

            // Dropping the hidden sidebar also drops its expanded file tree
            // and process snapshot. Git stays window-owned because the toolbar
            // remains visible while this panel is closed.
            if manager.isPanelVisible {
                RightSidebarView(manager: manager, git: git)
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
        .onAppear { syncGit() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            syncGit()
        }
        .onChange(of: commandCompletionSequences) { syncGit() }
        .onChange(of: manager.selectedProjectID) { syncGit() }
        .onChange(of: manager.selectedSession?.id) { syncGit() }
        .onChange(of: manager.selectedSession?.workingDirectory) { syncGit() }
        .onChange(of: manager.selectedSession?.foregroundDirectoryPath) { syncGit() }
        .onChange(of: manager.selectedProject?.customDirectory) { syncGit() }
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

    private func syncGit() {
        guard let project = manager.selectedProject,
              let session = project.selectedSession else {
            git.sync(root: "")
            return
        }
        let root = project.panelRoot(
            followingSessionAt: session.currentDirectoryPath,
            foregroundAt: session.foregroundDirectoryPath
        ).root
        git.sync(root: root)
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
        title: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
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

/// Project context for the active workspace. It stays deliberately compact so
/// terminal content remains the center of gravity below the tab strip.
private struct BottomToolbarView: View {
    @ObservedObject var model: GitStatusModel
    @ObservedObject private var themeChanges = Theme.changes
    let height: CGFloat
    let toggleGitPanel: () -> Void
    let hideToolbar: () -> Void

    @State private var isShowingBranches = false
    @State private var branchFilter = ""
    @State private var branchSearchFocusRequest: UInt = 0
    @State private var branchScrollRequest: UInt = 0
    @State private var isBranchButtonHovered = false
    @State private var isChangesButtonHovered = false
    @State private var isNoRepositoryButtonHovered = false
    @State private var hoveredBranch: String?

    private var filteredBranches: [String] {
        let query = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        var branches = query.isEmpty ? model.branches : model.branches.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        if let current = model.branch,
           let index = branches.firstIndex(of: current), index != branches.startIndex {
            branches.remove(at: index)
            branches.insert(current, at: branches.startIndex)
        }
        return branches
    }

    private var changesAccessibilityValue: String {
        guard model.totalChangeCount > 0 else { return String(localized: "Clean") }
        return String(localized: "+\(model.lineAdditions), −\(model.lineDeletions)")
    }

    var body: some View {
        HStack(spacing: 9) {
            if model.isRepo {
                branchButton
                changesButton
            } else {
                noRepositoryButton
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: height)
        .contentShape(Rectangle())
        .background {
            ToolbarContextMenuMonitor(hideToolbar: hideToolbar)
        }
        .background(Color(nsColor: Theme.background))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private var noRepositoryButton: some View {
        Button(action: toggleGitPanel) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("No Git Repository")
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isNoRepositoryButtonHovered
                            ? Color.primary.opacity(0.08)
                            : Color.clear
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isNoRepositoryButtonHovered = $0 }
    }

    private var branchButton: some View {
        Button {
            toggleBranchPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
                Text(verbatim: model.branch ?? "detached HEAD")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isBranchButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isBranchButtonHovered = $0 }
        .background {
            InstantPopoverPresenter(
                isPresented: $isShowingBranches,
                preferredEdge: .maxY,
                onPresent: {
                    guard isShowingBranches else { return }
                    branchSearchFocusRequest &+= 1
                    branchScrollRequest &+= 1
                },
                onDismiss: {
                    hoveredBranch = nil
                }
            ) {
                branchPicker
            }
        }
        .disabled(model.isBusy)
        .help("Switch Branch")
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD"))")
        )
    }

    private var changesButton: some View {
        Button(action: toggleGitPanel) {
            HStack(spacing: 8) {
                if model.totalChangeCount == 0 {
                    Circle()
                        .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .frame(width: 6, height: 6)
                    Text("Clean")
                } else {
                    Text(verbatim: "+\(model.lineAdditions)")
                        .foregroundStyle(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .monospacedDigit()
                    Text(verbatim: "−\(model.lineDeletions)")
                        .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.45))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isChangesButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isChangesButtonHovered = $0 }
        .help("Open Changes")
        .accessibilityLabel("Open Changes")
        .accessibilityValue(changesAccessibilityValue)
    }

    private var branchPicker: some View {
        VStack(spacing: 0) {
            BranchSearchField(
                text: $branchFilter,
                focusRequest: branchSearchFocusRequest
            ) {
                if filteredBranches.count == 1,
                   let branch = filteredBranches.first,
                   branch != model.branch {
                    selectBranch(branch)
                }
            }
            .frame(height: 22)
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredBranches.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(filteredBranches, id: \.self) { branch in
                                let isHovered = hoveredBranch == branch
                                Button {
                                    selectBranch(branch)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .semibold))
                                            .opacity(branch == model.branch ? 1 : 0)
                                        Text(verbatim: branch)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if branch == model.defaultBranch {
                                            Text(
                                                "default",
                                                comment: "Badge for the repository's default branch."
                                            )
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(
                                                isHovered
                                                    ? Color.white.opacity(0.85)
                                                    : Color(nsColor: .secondaryLabelColor)
                                            )
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule().fill(
                                                    isHovered
                                                        ? Color.white.opacity(0.18)
                                                        : Color.primary.opacity(0.07)
                                                )
                                            )
                                            .fixedSize()
                                        }
                                    }
                                    .foregroundStyle(isHovered ? Color.white : Color.primary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 26)
                                    .background {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(
                                                isHovered
                                                    ? Color(nsColor: .selectedContentBackgroundColor)
                                                    : Color.clear
                                            )
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { isHovered in
                                    if isHovered {
                                        hoveredBranch = branch
                                    } else if hoveredBranch == branch {
                                        hoveredBranch = nil
                                    }
                                }
                                .disabled(branch == model.branch || model.isBusy)
                                .id(branch)
                            }
                        }
                    }
                    .padding(5)
                }
                .onChange(of: branchScrollRequest) {
                    guard let branch = model.branch else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(branch, anchor: .top)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .frame(width: 260, height: 250)
        .background {
            VisualEffectView(material: .popover)
                .ignoresSafeArea()
        }
    }

    private func toggleBranchPicker() {
        if !isShowingBranches { branchFilter = "" }
        isShowingBranches.toggle()
    }

    private func selectBranch(_ branch: String) {
        isShowingBranches = false
        model.switchBranch(to: branch)
    }
}

/// NSSearchField supplies the standard macOS bezel, magnifier, clear button,
/// focus ring, and vibrancy-aware colors inside the native popover.
private struct BranchSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = String(localized: "Filter branches")
        field.setAccessibilityLabel(String(localized: "Filter branches"))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        guard context.coordinator.handledFocusRequest != focusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(field)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BranchSearchField
        var handledFocusRequest: UInt?

        init(parent: BranchSearchField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest == 0 ? 0 : nil
        }

        func focus(_ field: NSSearchField, attemptsRemaining: Int = 6) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                if let window = field.window, window.makeFirstResponder(field) { return }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}

/// SwiftUI anchors a context menu to this full-width toolbar view. A local
/// AppKit monitor retains the same hit area while presenting from the actual
/// right-click event, so the menu appears at the pointer instead.
private struct ToolbarContextMenuMonitor: NSViewRepresentable {
    let hideToolbar: () -> Void

    func makeNSView(context: Context) -> ToolbarContextMenuMonitorView {
        let view = ToolbarContextMenuMonitorView()
        view.hideToolbar = hideToolbar
        return view
    }

    func updateNSView(_ nsView: ToolbarContextMenuMonitorView, context: Context) {
        nsView.hideToolbar = hideToolbar
    }

    static func dismantleNSView(
        _ nsView: ToolbarContextMenuMonitorView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
private final class ToolbarContextMenuMonitorView: NSView {
    var hideToolbar: () -> Void = {}
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self, weak window] event in
            let input = ToolbarContextMenuEvent(event)
            let output: ToolbarContextMenuEvent = MainActor.assumeIsolated {
                guard let self,
                      let window,
                      let event = input.value,
                      event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return input }

                let menu = NSMenu()
                let hideItem = NSMenuItem(
                    title: String(localized: "Hide"),
                    action: #selector(self.hideToolbarFromMenu),
                    keyEquivalent: ""
                )
                hideItem.target = self
                menu.addItem(hideItem)
                menu.update()
                var screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                // The toolbar sits at the screen's lower edge. Position the
                // menu upward so its bottom edge, rather than its top edge,
                // meets the pointer without AppKit relocating the whole menu.
                screenPoint.y += menu.size.height
                _ = menu.popUp(positioning: nil, at: screenPoint, in: nil)
                return ToolbarContextMenuEvent(nil)
            }
            return output.value
        }
    }

    @objc private func hideToolbarFromMenu() {
        hideToolbar()
    }

    func detach() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

/// Local event monitors run synchronously on AppKit's main event thread.
private struct ToolbarContextMenuEvent: @unchecked Sendable {
    let value: NSEvent?

    init(_ value: NSEvent?) {
        self.value = value
    }
}

/// A single AppKit-owned popover avoids SwiftUI's re-entrant presentation path:
/// rapid binding changes reconcile against `isShown`, and generation checks
/// prevent a stale close callback from dismissing a newer presentation.
private struct InstantPopoverPresenter<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let onPresent: () -> Void
    let onDismiss: () -> Void
    let content: () -> PopoverContent

    init(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge,
        onPresent: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) {
        _isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.onPresent = onPresent
        self.onDismiss = onDismiss
        self.content = content
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: InstantPopoverPresenter
        let popover: NSPopover
        let hostingController: NSHostingController<PopoverContent>
        private var presentationGeneration: UInt = 0

        init(parent: InstantPopoverPresenter) {
            self.parent = parent
            popover = NSPopover()
            hostingController = NSHostingController(rootView: parent.content())
            super.init()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = hostingController
        }

        func reconcile(parent: InstantPopoverPresenter, anchor: NSView) {
            self.parent = parent
            hostingController.rootView = parent.content()
            popover.animates = false

            if parent.isPresented {
                guard !popover.isShown, anchor.window != nil else { return }
                presentationGeneration &+= 1
                hostingController.view.layoutSubtreeIfNeeded()
                let fittingSize = hostingController.view.fittingSize
                if fittingSize.width > 0, fittingSize.height > 0 {
                    popover.contentSize = fittingSize
                }
                popover.show(
                    relativeTo: anchor.bounds,
                    of: anchor,
                    preferredEdge: parent.preferredEdge
                )
            } else if popover.isShown {
                popover.close()
            }
        }

        func popoverWillShow(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidShow(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      self.popover.isShown,
                      self.parent.isPresented else { return }
                self.parent.onPresent()
            }
        }

        func popoverWillClose(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidClose(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.popover.isShown else { return }
                self.parent.onDismiss()
                if self.parent.isPresented {
                    self.parent.isPresented = false
                }
            }
        }

        func dismantle() {
            popover.delegate = nil
            popover.animates = false
            popover.close()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.reconcile(parent: self, anchor: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}

/// Slim bar above the terminal: the selected project's sessions as
/// horizontal tabs, with sidebar controls at the outer edges. Doubles as
/// window-drag space.
private struct MainHeaderView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var themeChanges = Theme.changes

    /// Keep an always-available grab target beside the trailing controls,
    /// even when the session strip is full.
    private let minimumWindowDragWidth: CGFloat = 100

    /// With the left sidebar hidden the header slides under the window's
    /// traffic-light buttons, so inset its content to clear them.
    private var leadingInset: CGFloat {
        manager.isLeftSidebarVisible ? 8 : 78
    }

    /// A hidden sidebar moves its toggle into this header. Reserve the
    /// button and its following HStack spacing before sizing the tab strip.
    private var hiddenLeftSidebarControlWidth: CGFloat {
        manager.isLeftSidebarVisible ? 0 : 32
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                if !manager.isLeftSidebarVisible {
                    ChromeIconButton(
                        systemImage: "sidebar.left",
                        tooltip: "Toggle Left Sidebar (⌘B)",
                        tooltipAlignment: .leading
                    ) {
                        manager.toggleLeftSidebar()
                    }
                }
                if let project = manager.selectedProject {
                    // Everything in the header that isn't the scrollable tab
                    // strip: leading inset, an optional left-sidebar control,
                    // trailing padding (8), HStack spacings (16), right-sidebar
                    // toggle (24), "+" and spacing (26), the minimum drag
                    // target (100), and the exit-zoom button (24 + 8 spacing)
                    // while shown.
                    SessionTabsView(
                        project: project,
                        maxStripWidth: max(
                            0,
                            geo.size.width - leadingInset - hiddenLeftSidebarControlWidth
                                - 74 - minimumWindowDragWidth
                                - (manager.isPaneZoomed ? 32 : 0)
                        )
                    )
                }
                WindowDragArea()
                    .frame(minWidth: minimumWindowDragWidth, maxWidth: .infinity)
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
                    ChromeIconButton(
                        systemImage: "sidebar.right",
                        tooltip: "Toggle Right Sidebar (⇧⌘B)"
                    ) {
                        manager.toggleSidebar()
                    }
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
    @State private var tabSizes: [UUID: CGSize] = [:]
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
            // Selection is not the only thing that can hide the active tab.
            // Keep it visible when the window/sidebar changes the viewport,
            // tabs are inserted or reordered, or a live title/rename changes
            // the width of content before it.
            .onChange(of: maxStripWidth) {
                scrollToSelectedTab(using: proxy)
            }
            .onChange(of: project.tabs.map(\.id)) {
                scrollToSelectedTab(using: proxy)
            }
            .onChange(of: tabSizes) {
                scrollToSelectedTab(using: proxy)
            }
            .onAppear {
                // Restored sessions may open with an off-screen active tab.
                DispatchQueue.main.async {
                    scrollToSelectedTab(using: proxy)
                }
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

            ChromeIconButton(
                systemImage: "plus",
                tooltip: "New Session (⌘T)",
                font: .system(size: 10, weight: .semibold),
                iconSize: 14,
                tooltipAlignment: .leading
            ) {
                project.newSession()
            }
        }
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            tabFrames = frames
            let sizes = frames.mapValues(\.size)
            if sizes != tabSizes {
                tabSizes = sizes
            }
        }
    }

    /// `anchor: nil` moves only as far as needed and is a no-op when the
    /// selected tab is already fully inside the strip.
    private func scrollToSelectedTab(using proxy: ScrollViewProxy) {
        guard let id = project.selectedTabID,
              project.tabs.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id)
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
        if case .browser(let browser) = tab.focusedContent,
           !browser.urlString.isEmpty {
            Button("Open in Default Browser") {
                browser.openInDefaultBrowser()
            }
            .disabled(browser.shareURL == nil)
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(browser.urlString, forType: .string)
            }
            Divider()
        }
        Button("Close") { project.close(tab) }
        Button("Close Others") { project.closeOthers(tab) }
            .disabled(project.tabs.count <= 1)
        Button("Close Tabs to the Right") { project.closeToRight(of: tab) }
            .disabled(project.tabs.last?.id == tab.id)
        Divider()
        Button("Close Files") { project.closeFiles() }
            .disabled(!project.hasFiles)
        Button("Close Diffs") { project.closeDiffs() }
            .disabled(!project.hasDiffs)
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
                browserIcon: focusedBrowser,
                fileIconPath: focusedFileIconPath,
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
            case .browser(let browser):
                BrowserTabLabel(browser: browser, customTitle: tab.customName, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
            case .diff(let diff):
                DiffTabLabel(
                    diff: diff,
                    customTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
                    select: select,
                    close: close
                )
            case nil:
                EmptyView()
            }
        }
    }

    private var focusedBrowser: BrowserTab? {
        if case .browser(let browser) = tab.focusedContent {
            browser
        } else {
            nil
        }
    }

    private var focusedFileIconPath: String? {
        tab.focusedContent?.fileIconPath
    }
}

/// Inline editor shown in place of a tab while it's renamed — the same
/// affordance as the project row's rename. Commits on Return or focus loss,
/// cancels on Escape; an empty name returns the tab to its automatic title.
private struct TabRenameChrome: View {
    @ObservedObject private var themeChanges = Theme.changes
    let systemImage: String
    let browserIcon: BrowserTab?
    let fileIconPath: String?
    let commit: (String) -> Void
    let end: () -> Void

    @State private var draft: String
    /// Set by the first commit/cancel so the focus-loss handler that fires
    /// while the field is being torn down doesn't commit a second time.
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        systemImage: String,
        browserIcon: BrowserTab?,
        fileIconPath: String?,
        initialValue: String,
        commit: @escaping (String) -> Void,
        end: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.browserIcon = browserIcon
        self.fileIconPath = fileIconPath
        self.commit = commit
        self.end = end
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        HStack(spacing: 5) {
            if let browserIcon {
                BrowserFaviconView(browser: browserIcon, size: 11)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
            } else if let fileIconPath {
                MaterialFileIconView(path: fileIconPath, size: 12)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
            }
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
            fileIconPath: file.path,
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

private struct BrowserTabLabel: View {
    @ObservedObject var browser: BrowserTab
    /// User-assigned tab name overriding the webpage title.
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "globe",
            browserIcon: browser,
            title: customTitle ?? browser.title,
            paneCount: paneCount,
            isSelected: isSelected,
            select: select,
            close: close
        )
        .help(browser.urlString)
    }
}

private struct DiffTabLabel: View {
    @ObservedObject var diff: DiffTab
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "plus.forwardslash.minus",
            fileIconPath: diff.path,
            title: customTitle ?? diff.title,
            paneCount: paneCount,
            isSelected: isSelected,
            isDirty: diff.isDirty,
            select: select,
            close: close
        )
        .help(diff.path)
    }
}

private struct TabItemChrome: View {
    @ObservedObject private var themeChanges = Theme.changes
    let systemImage: String
    var browserIcon: BrowserTab? = nil
    var fileIconPath: String? = nil
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
                if let browserIcon {
                    BrowserFaviconView(browser: browserIcon, size: 11)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                : AnyShapeStyle(.tertiary)
                        )
                        .opacity(isSelected ? 1 : 0.78)
                } else if let fileIconPath {
                    MaterialFileIconView(
                        path: fileIconPath,
                        size: 12,
                        opacity: isSelected ? 1 : 0.82
                    )
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                : AnyShapeStyle(.tertiary)
                        )
                }
                Text(verbatim: title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                if paneCount > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 7.5, weight: .semibold))
                        Text(verbatim: "\(paneCount)")
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
