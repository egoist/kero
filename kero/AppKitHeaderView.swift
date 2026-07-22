//
//  AppKitHeaderView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Transitional bridge for the first SwiftUI -> AppKit migration slice. The
/// window, sidebars and pane area remain SwiftUI-owned while this controller
/// owns the always-visible header and tab strip.
struct AppKitHeaderView: NSViewControllerRepresentable {
    let manager: TerminalManager

    func makeNSViewController(context: Context) -> AppKitHeaderViewController {
        AppKitHeaderViewController(manager: manager)
    }

    func updateNSViewController(
        _ controller: AppKitHeaderViewController, context: Context
    ) {
        controller.setManager(manager)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: AppKitHeaderViewController,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: HeaderRootView.height)
    }

    static func dismantleNSViewController(
        _ controller: AppKitHeaderViewController, coordinator: ()
    ) {
        controller.invalidate()
    }
}

@MainActor
final class AppKitHeaderViewController: NSViewController {
    private var manager: TerminalManager
    private weak var project: Project?

    private let headerView = HeaderRootView()

    private var managerCancellables: Set<AnyCancellable> = []
    private var projectCancellables: Set<AnyCancellable> = []
    private var tabCancellables: [UUID: Set<AnyCancellable>] = [:]
    private var contentCancellables: [UUID: Set<AnyCancellable>] = [:]

    private var draggedTabID: UUID?
    private var lastDragTargetID: UUID?

    init(manager: TerminalManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = headerView

        headerView.tabStrip.delegate = self
        headerView.newSessionButton.target = self
        headerView.newSessionButton.action = #selector(newSession)
        headerView.sidebarButton.target = self
        headerView.sidebarButton.action = #selector(toggleSidebar)

        bindManager()
    }

    func setManager(_ manager: TerminalManager) {
        guard self.manager !== manager else { return }
        invalidate()
        self.manager = manager
        guard isViewLoaded else { return }
        bindManager()
    }

    func invalidate() {
        cancelDrag()
        managerCancellables.removeAll()
        unbindProject()
    }

    deinit {
        NSCursor.arrow.set()
    }

    // MARK: - Observation

    /// The window-level model intentionally republishes all nested project
    /// changes. The header avoids that broad stream and observes only the
    /// handful of properties that affect its own controls.
    private func bindManager() {
        managerCancellables.removeAll()

        Publishers.CombineLatest(manager.$projects, manager.$selectedProjectID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] projects, selectedID in
                guard let self else { return }
                let selected = projects.first { $0.id == selectedID }
                self.bindProject(selected)
            }
            .store(in: &managerCancellables)

        manager.$isLeftSidebarVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.headerView.leadingInset = visible ? 8 : 78
            }
            .store(in: &managerCancellables)

        manager.$isPanelVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.headerView.sidebarButton.contentTintColor = visible
                    ? Theme.cursor : .secondaryLabelColor
            }
            .store(in: &managerCancellables)

        // Set initial state synchronously; @Published delivery above is queued
        // so it cannot observe a willSet value before the model assignment.
        bindProject(manager.selectedProject)
        headerView.leadingInset = manager.isLeftSidebarVisible ? 8 : 78
        headerView.sidebarButton.contentTintColor = manager.isPanelVisible
            ? Theme.cursor : .secondaryLabelColor
    }

    private func bindProject(_ project: Project?) {
        if self.project === project { return }
        unbindProject()
        self.project = project
        headerView.hasProject = project != nil

        guard let project else {
            headerView.tabStrip.update([])
            return
        }

        project.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak project] tabs in
                guard let self, self.project === project else { return }
                self.syncTabs(tabs)
            }
            .store(in: &projectCancellables)

        project.$selectedTabID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak project] selectedID in
                guard let self, self.project === project else { return }
                self.refreshSelection(selectedID, reveal: true)
            }
            .store(in: &projectCancellables)

        syncTabs(project.tabs)
        refreshSelection(project.selectedTabID, reveal: true)
    }

    private func unbindProject() {
        cancelDrag()
        projectCancellables.removeAll()
        tabCancellables.removeAll()
        contentCancellables.removeAll()
        project = nil
        headerView.hasProject = false
        headerView.tabStrip.update([])
    }

    private func syncTabs(_ tabs: [PaneTab]) {
        let liveIDs = Set(tabs.map(\.id))
        for id in Array(tabCancellables.keys) where !liveIDs.contains(id) {
            tabCancellables[id] = nil
            contentCancellables[id] = nil
            if draggedTabID == id { cancelDrag() }
        }
        for tab in tabs where tabCancellables[tab.id] == nil {
            bindTab(tab)
        }

        let selectedID = project?.selectedTabID
        let snapshots = tabs.map { snapshot(for: $0, selectedID: selectedID) }
        headerView.tabStrip.update(snapshots)
        headerView.needsLayout = true
    }

    private func bindTab(_ tab: PaneTab) {
        var cancellables: Set<AnyCancellable> = []

        tab.$columns
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                self.bindFocusedContent(for: tab)
                self.refreshTab(tab.id)
            }
            .store(in: &cancellables)

        tab.$focusedPaneID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                self.bindFocusedContent(for: tab)
                self.refreshTab(tab.id)
            }
            .store(in: &cancellables)

        tabCancellables[tab.id] = cancellables
        bindFocusedContent(for: tab)
    }

    private func bindFocusedContent(for tab: PaneTab) {
        var cancellables: Set<AnyCancellable> = []

        switch tab.focusedContent {
        case .session(let session):
            session.$title
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let tab else { return }
                    self?.refreshTab(tab.id)
                }
                .store(in: &cancellables)
        case .file(let file):
            Publishers.CombineLatest(
                file.$path.removeDuplicates(),
                file.$isDirty.removeDuplicates()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] _ in
                guard let tab else { return }
                self?.refreshTab(tab.id)
            }
            .store(in: &cancellables)
        case .diff, nil:
            break
        }

        contentCancellables[tab.id] = cancellables
    }

    private func refreshTab(_ id: UUID) {
        guard let project,
              let tab = project.tabs.first(where: { $0.id == id })
        else { return }
        headerView.tabStrip.update(
            snapshot(for: tab, selectedID: project.selectedTabID)
        )
        headerView.needsLayout = true
    }

    private func refreshSelection(_ selectedID: UUID?, reveal: Bool) {
        guard let project else { return }
        for tab in project.tabs {
            headerView.tabStrip.setSelected(tab.id == selectedID, for: tab.id)
        }
        guard reveal, let selectedID else { return }
        DispatchQueue.main.async { [weak self] in
            self?.headerView.tabStrip.reveal(selectedID)
        }
    }

    private func snapshot(
        for tab: PaneTab, selectedID: UUID?
    ) -> HeaderTabSnapshot {
        let title: String
        let systemImage: String
        let isDirty: Bool
        let help: String?

        switch tab.focusedContent {
        case .session(let session):
            title = session.title
            systemImage = "terminal"
            isDirty = false
            help = nil
        case .file(let file):
            title = file.name
            systemImage = "doc.text"
            isDirty = file.isDirty
            help = file.path
        case .diff(let diff):
            title = diff.title
            systemImage = "plus.forwardslash.minus"
            isDirty = false
            help = diff.path
        case nil:
            title = "Tab"
            systemImage = "square"
            isDirty = false
            help = nil
        }

        return HeaderTabSnapshot(
            id: tab.id,
            title: title,
            systemImage: systemImage,
            paneCount: tab.allPanes.count,
            isSelected: tab.id == selectedID,
            isDirty: isDirty,
            help: help
        )
    }

    // MARK: - Controls

    @objc private func newSession() {
        project?.newSession()
    }

    @objc private func toggleSidebar() {
        manager.toggleSidebar()
    }

    private func tab(id: UUID) -> PaneTab? {
        project?.tabs.first { $0.id == id }
    }

    private func cancelDrag() {
        if let draggedTabID {
            headerView.tabStrip.setDragging(false, for: draggedTabID)
        }
        draggedTabID = nil
        lastDragTargetID = nil
        NSCursor.arrow.set()
    }
}

// MARK: - Tab strip delegate

@MainActor
extension AppKitHeaderViewController: HeaderTabStripDelegate {
    func tabStripDidSelect(_ id: UUID) {
        project?.selectedTabID = id
    }

    func tabStripDidClose(_ id: UUID) {
        guard let tab = tab(id: id) else { return }
        project?.close(tab)
    }

    func tabStripDidBeginDragging(_ id: UUID) {
        draggedTabID = id
        lastDragTargetID = nil
        headerView.tabStrip.setDragging(true, for: id)
        NSCursor.closedHand.set()
    }

    func tabStripDidDrag(_ id: UUID, to point: NSPoint) {
        guard draggedTabID == id,
              let targetID = headerView.tabStrip.tabID(at: point),
              targetID != id
        else {
            lastDragTargetID = nil
            return
        }
        guard targetID != lastDragTargetID else { return }
        lastDragTargetID = targetID
        project?.moveTab(id, to: targetID)
        if let tabs = project?.tabs {
            syncTabs(tabs)
        }
    }

    func tabStripDidEndDragging(_ id: UUID) {
        guard draggedTabID == id else { return }
        cancelDrag()
    }

    func tabStripMenu(for id: UUID) -> NSMenu? {
        guard let project, let tab = tab(id: id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        if case .file = tab.focusedContent {
            menu.addItem(menuItem("Reveal in Finder", action: #selector(revealFile(_:)), id: id))
            menu.addItem(menuItem("Copy Absolute Path", action: #selector(copyFilePath(_:)), id: id))
            menu.addItem(.separator())
        }

        menu.addItem(menuItem("Close", action: #selector(closeTab(_:)), id: id))
        let closeOthers = menuItem("Close Others", action: #selector(closeOtherTabs(_:)), id: id)
        closeOthers.isEnabled = project.tabs.count > 1
        menu.addItem(closeOthers)
        let closeRight = menuItem("Close Tabs to the Right", action: #selector(closeTabsToRight(_:)), id: id)
        closeRight.isEnabled = project.tabs.last?.id != id
        menu.addItem(closeRight)
        menu.addItem(.separator())
        menu.addItem(menuItem("Close All", action: #selector(closeAllTabs(_:)), id: id))
        return menu
    }

    private func menuItem(
        _ title: String, action: Selector, id: UUID
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id as NSUUID
        return item
    }

    private func menuTab(_ sender: NSMenuItem) -> PaneTab? {
        guard let id = sender.representedObject as? NSUUID else { return nil }
        return tab(id: id as UUID)
    }

    @objc private func revealFile(_ sender: NSMenuItem) {
        guard case .file(let file)? = menuTab(sender)?.focusedContent else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }

    @objc private func copyFilePath(_ sender: NSMenuItem) {
        guard case .file(let file)? = menuTab(sender)?.focusedContent else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }

    @objc private func closeTab(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        project?.close(tab)
    }

    @objc private func closeOtherTabs(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        project?.closeOthers(tab)
    }

    @objc private func closeTabsToRight(_ sender: NSMenuItem) {
        guard let tab = menuTab(sender) else { return }
        project?.closeToRight(of: tab)
    }

    @objc private func closeAllTabs(_ sender: NSMenuItem) {
        project?.closeAll()
    }
}

// MARK: - Header layout

@MainActor
private final class HeaderRootView: NSView {
    static let height: CGFloat = 38

    let tabScrollView = HeaderTabScrollView()
    let tabStrip = HeaderTabStripView()
    let newSessionButton = HeaderIconButton(
        systemImage: "plus", pointSize: 10, weight: .semibold
    )
    let dragRegion = WindowDragRegionView()
    let sidebarButton = HeaderIconButton(
        systemImage: "sidebar.right", pointSize: 12, weight: .medium
    )

    var leadingInset: CGFloat = 8 {
        didSet {
            guard leadingInset != oldValue else { return }
            needsLayout = true
        }
    }

    var hasProject = false {
        didSet {
            guard hasProject != oldValue else { return }
            tabScrollView.isHidden = !hasProject
            newSessionButton.isHidden = !hasProject
            sidebarButton.isHidden = !hasProject
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        tabScrollView.documentView = tabStrip
        tabScrollView.onContentWidthChanged = { [weak self] in
            self?.needsLayout = true
        }

        newSessionButton.toolTip = "New Session (⌘T)"
        newSessionButton.setAccessibilityLabel("New Session")
        sidebarButton.toolTip = "Toggle Sidebar (⇧⌘B)"
        sidebarButton.setAccessibilityLabel("Toggle Sidebar")
        sidebarButton.contentTintColor = .secondaryLabelColor

        addSubview(tabScrollView)
        addSubview(newSessionButton)
        addSubview(dragRegion)
        addSubview(sidebarButton)

        tabScrollView.isHidden = true
        newSessionButton.isHidden = true
        sidebarButton.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    override func layout() {
        super.layout()

        let tabHeight: CGFloat = 22
        let tabY = floor((bounds.height - tabHeight) / 2)
        let sidebarHeight: CGFloat = 24
        let sidebarY = floor((bounds.height - sidebarHeight) / 2)
        let trailingInset: CGFloat = 8

        guard hasProject else {
            dragRegion.frame = NSRect(
                x: leadingInset,
                y: 0,
                width: max(0, bounds.width - leadingInset - trailingInset),
                height: bounds.height
            )
            return
        }

        let sidebarWidth: CGFloat = 24
        let plusWidth: CGFloat = 22
        let innerSpacing: CGFloat = 4
        let outerSpacing: CGFloat = 8
        let minimumDragWidth: CGFloat = 26

        let rightEdge = max(leadingInset, bounds.width - trailingInset)
        let canShowSidebar = rightEdge - leadingInset >= sidebarWidth
        sidebarButton.isHidden = !canShowSidebar

        guard canShowSidebar else {
            tabScrollView.isHidden = true
            newSessionButton.isHidden = true
            dragRegion.frame = NSRect(
                x: leadingInset,
                y: 0,
                width: max(0, rightEdge - leadingInset),
                height: bounds.height
            )
            return
        }

        sidebarButton.frame = NSRect(
            x: rightEdge - sidebarWidth,
            y: sidebarY,
            width: sidebarWidth,
            height: sidebarHeight
        )

        // Below the width where both fixed actions fit, retain a safe window
        // drag surface and hide the "+"/tabs. Their keyboard/menu commands stay
        // available, and no control can overlap or extend beyond the view.
        let canShowNewSession =
            sidebarButton.frame.minX - leadingInset >= innerSpacing + plusWidth
        newSessionButton.isHidden = !canShowNewSession
        tabScrollView.isHidden = !canShowNewSession
        guard canShowNewSession else {
            dragRegion.frame = NSRect(
                x: leadingInset,
                y: 0,
                width: max(0, sidebarButton.frame.minX - outerSpacing - leadingInset),
                height: bounds.height
            )
            return
        }

        // Keep the fixed controls reachable first. The tab viewport gives up
        // width before the blank drag surface or either action button does.
        let maximumTabWidth = max(
            0,
            sidebarButton.frame.minX - outerSpacing - outerSpacing
                - minimumDragWidth - plusWidth - innerSpacing - leadingInset
        )
        let tabWidth = min(tabScrollView.preferredContentWidth, maximumTabWidth)
        tabScrollView.frame = NSRect(
            x: leadingInset,
            y: tabY,
            width: tabWidth,
            height: tabHeight
        )
        newSessionButton.frame = NSRect(
            x: tabScrollView.frame.maxX + innerSpacing,
            y: tabY,
            width: plusWidth,
            height: tabHeight
        )

        let dragX = newSessionButton.frame.maxX + outerSpacing
        let dragRight = sidebarButton.frame.minX - outerSpacing
        dragRegion.frame = NSRect(
            x: dragX,
            y: 0,
            width: max(0, dragRight - dragX),
            height: bounds.height
        )

        tabScrollView.updateOverflowMask()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let separator = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        separator.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        sidebarButton.needsDisplay = true
        newSessionButton.needsDisplay = true
        tabStrip.refreshAppearance()
    }
}

@MainActor
private final class HeaderIconButton: NSButton {
    init(systemImage: String, pointSize: CGFloat, weight: NSFont.Weight) {
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            .init(pointSize: pointSize, weight: weight)
        )
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        refusesFirstResponder = true
        contentTintColor = .secondaryLabelColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Only this empty header region can move the window. Tabs and controls remain
/// ordinary hit-test siblings, so their drag/click streams cannot be claimed
/// by the hidden title bar.
@MainActor
private final class WindowDragRegionView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            window.performTitlebarDoubleClickAction()
        } else {
            window.performDrag(with: event)
        }
    }
}

// MARK: - Scrolling and overflow

@MainActor
private final class HeaderTabScrollView: NSScrollView {
    var onContentWidthChanged: (() -> Void)?
    private let overflowMaskLayer = CAGradientLayer()

    var preferredContentWidth: CGFloat {
        (documentView as? HeaderTabStripView)?.contentWidth ?? 0
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        wantsLayer = true

        overflowMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        overflowMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        updateOverflowMask()
    }

    func contentWidthDidChange() {
        onContentWidthChanged?()
        updateOverflowMask()
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        updateOverflowMask()
    }

    func updateOverflowMask() {
        guard bounds.width > 0, let documentView else {
            layer?.mask = nil
            return
        }

        let visible = contentView.bounds
        let contentWidth = documentView.frame.width
        let hasLeftOverflow = visible.minX > 0.5
        let hasRightOverflow = visible.maxX < contentWidth - 0.5
        guard hasLeftOverflow || hasRightOverflow else {
            layer?.mask = nil
            return
        }

        overflowMaskLayer.frame = bounds
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        let fade = min(0.5, 20 / max(bounds.width, 1))
        overflowMaskLayer.colors = [
            hasLeftOverflow ? clear : opaque,
            opaque,
            opaque,
            hasRightOverflow ? clear : opaque,
        ]
        overflowMaskLayer.locations = [
            0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1,
        ]
        if layer?.mask !== overflowMaskLayer {
            layer?.mask = overflowMaskLayer
        }
    }
}

// MARK: - Tabs

private struct HeaderTabSnapshot: Equatable {
    let id: UUID
    let title: String
    let systemImage: String
    let paneCount: Int
    let isSelected: Bool
    let isDirty: Bool
    let help: String?
}

@MainActor
private protocol HeaderTabStripDelegate: AnyObject {
    func tabStripDidSelect(_ id: UUID)
    func tabStripDidClose(_ id: UUID)
    func tabStripDidBeginDragging(_ id: UUID)
    func tabStripDidDrag(_ id: UUID, to point: NSPoint)
    func tabStripDidEndDragging(_ id: UUID)
    func tabStripMenu(for id: UUID) -> NSMenu?
}

@MainActor
private final class HeaderTabStripView: NSView {
    static let itemHeight: CGFloat = 22

    weak var delegate: HeaderTabStripDelegate?

    private let spacing: CGFloat = 3
    private var orderedIDs: [UUID] = []
    private var views: [UUID: HeaderTabItemView] = [:]

    private(set) var contentWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ snapshots: [HeaderTabSnapshot]) {
        let newIDs = snapshots.map(\.id)
        let liveIDs = Set(newIDs)

        for (id, item) in views where !liveIDs.contains(id) {
            item.removeFromSuperview()
            views[id] = nil
        }

        for snapshot in snapshots {
            let item: HeaderTabItemView
            if let existing = views[snapshot.id] {
                item = existing
            } else {
                item = HeaderTabItemView(id: snapshot.id)
                item.delegate = self
                views[snapshot.id] = item
                addSubview(item)
            }
            item.update(snapshot)
        }

        orderedIDs = newIDs
        tileTabs()
    }

    func update(_ snapshot: HeaderTabSnapshot) {
        guard let item = views[snapshot.id] else { return }
        let oldWidth = item.preferredWidth
        item.update(snapshot)
        if item.preferredWidth != oldWidth {
            tileTabs()
        }
    }

    func setSelected(_ selected: Bool, for id: UUID) {
        views[id]?.setSelected(selected)
    }

    func setDragging(_ dragging: Bool, for id: UUID) {
        views[id]?.alphaValue = dragging ? 0.65 : 1
    }

    func reveal(_ id: UUID) {
        guard let item = views[id] else { return }
        scrollToVisible(item.frame)
        (enclosingScrollView as? HeaderTabScrollView)?.updateOverflowMask()
    }

    func tabID(at point: NSPoint) -> UUID? {
        orderedIDs.first { id in
            guard let item = views[id] else { return false }
            return item.frame.contains(point)
        }
    }

    func refreshAppearance() {
        for item in views.values {
            item.refreshAppearance()
        }
    }

    private func tileTabs() {
        var x: CGFloat = 0
        for id in orderedIDs {
            guard let item = views[id] else { continue }
            item.frame = NSRect(
                x: x,
                y: 0,
                width: item.preferredWidth,
                height: Self.itemHeight
            )
            x = item.frame.maxX + spacing
        }

        contentWidth = max(0, x - (orderedIDs.isEmpty ? 0 : spacing))
        let oldOrigin = frame.origin
        frame = NSRect(
            x: oldOrigin.x,
            y: oldOrigin.y,
            width: contentWidth,
            height: Self.itemHeight
        )
        needsDisplay = true
        (enclosingScrollView as? HeaderTabScrollView)?.contentWidthDidChange()
    }
}

@MainActor
extension HeaderTabStripView: HeaderTabItemDelegate {
    func tabItemDidSelect(_ id: UUID) {
        delegate?.tabStripDidSelect(id)
    }

    func tabItemDidClose(_ id: UUID) {
        delegate?.tabStripDidClose(id)
    }

    func tabItemDidBeginDragging(_ id: UUID) {
        delegate?.tabStripDidBeginDragging(id)
    }

    func tabItemDidDrag(_ id: UUID, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        delegate?.tabStripDidDrag(id, to: point)
    }

    func tabItemDidEndDragging(_ id: UUID) {
        delegate?.tabStripDidEndDragging(id)
    }

    func tabItemMenu(for id: UUID) -> NSMenu? {
        delegate?.tabStripMenu(for: id)
    }
}

@MainActor
private protocol HeaderTabItemDelegate: AnyObject {
    func tabItemDidSelect(_ id: UUID)
    func tabItemDidClose(_ id: UUID)
    func tabItemDidBeginDragging(_ id: UUID)
    func tabItemDidDrag(_ id: UUID, event: NSEvent)
    func tabItemDidEndDragging(_ id: UUID)
    func tabItemMenu(for id: UUID) -> NSMenu?
}

@MainActor
private final class HeaderTabItemView: NSView {
    let id: UUID
    weak var delegate: HeaderTabItemDelegate?

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let paneIconView = NSImageView()
    private let paneCountField = NSTextField(labelWithString: "")
    private let trailingStatusView = TabTrailingStatusView()
    private let closeButton = HeaderIconButton(
        systemImage: "xmark", pointSize: 8, weight: .bold
    )

    private var snapshot: HeaderTabSnapshot?
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var mouseDownPoint: NSPoint?
    private var dragging = false

    private static let titleFont = NSFont.systemFont(ofSize: 11.5)
    private static let countFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    var preferredWidth: CGFloat {
        guard let snapshot else { return 0 }
        let iconWidth = ceil(iconView.image?.size.width ?? 10)
        let titleWidth = ceil((snapshot.title as NSString).size(
            withAttributes: [.font: Self.titleFont]
        ).width)
        let paneWidth: CGFloat = snapshot.paneCount > 1
            ? 5 + 9 + 2 + ceil(("\(snapshot.paneCount)" as NSString).size(
                withAttributes: [.font: Self.countFont]
            ).width)
            : 0
        return 9 + iconWidth + 5 + titleWidth + paneWidth + 5 + 14 + 5
    }

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)

        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = .init(pointSize: 9, weight: .medium)

        titleField.font = Self.titleFont
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1

        paneIconView.image = NSImage(
            systemSymbolName: "square.split.2x1",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 7.5, weight: .semibold))
        paneIconView.imageScaling = .scaleProportionallyDown
        paneCountField.font = Self.countFont

        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setAccessibilityLabel("Close Tab")
        closeButton.isHidden = true

        iconView.setAccessibilityElement(false)
        titleField.setAccessibilityElement(false)
        paneIconView.setAccessibilityElement(false)
        paneCountField.setAccessibilityElement(false)
        trailingStatusView.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        addSubview(iconView)
        addSubview(titleField)
        addSubview(paneIconView)
        addSubview(paneCountField)
        addSubview(trailingStatusView)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ snapshot: HeaderTabSnapshot) {
        let iconChanged = self.snapshot?.systemImage != snapshot.systemImage
        self.snapshot = snapshot

        if iconChanged {
            iconView.image = NSImage(
                systemSymbolName: snapshot.systemImage,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        }
        titleField.stringValue = snapshot.title
        paneCountField.stringValue = "\(snapshot.paneCount)"
        paneIconView.isHidden = snapshot.paneCount <= 1
        paneCountField.isHidden = snapshot.paneCount <= 1
        toolTip = snapshot.help
        trailingStatusView.isDirty = snapshot.isDirty
        setAccessibilityLabel(snapshot.title)
        setAccessibilitySelected(snapshot.isSelected)
        setAccessibilityValue(snapshot.isSelected ? "Selected" : "Not selected")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close") { [weak self] in
                guard let self else { return false }
                self.delegate?.tabItemDidClose(self.id)
                return true
            },
        ])
        updateColors()
        updateHoverState()
        needsLayout = true
        needsDisplay = true
    }

    func setSelected(_ selected: Bool) {
        guard var snapshot, snapshot.isSelected != selected else { return }
        snapshot = HeaderTabSnapshot(
            id: snapshot.id,
            title: snapshot.title,
            systemImage: snapshot.systemImage,
            paneCount: snapshot.paneCount,
            isSelected: selected,
            isDirty: snapshot.isDirty,
            help: snapshot.help
        )
        self.snapshot = snapshot
        setAccessibilitySelected(selected)
        setAccessibilityValue(selected ? "Selected" : "Not selected")
        updateColors()
        needsDisplay = true
    }

    func refreshAppearance() {
        updateColors()
        trailingStatusView.needsDisplay = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let snapshot else { return }

        let centerY = bounds.midY
        var x: CGFloat = 9
        let iconSize = iconView.image?.size ?? NSSize(width: 10, height: 10)
        iconView.frame = NSRect(
            x: x,
            y: floor(centerY - iconSize.height / 2),
            width: ceil(iconSize.width),
            height: ceil(iconSize.height)
        )
        x = iconView.frame.maxX + 5

        let trailingWidth: CGFloat = 14
        let trailingX = bounds.width - 5 - trailingWidth
        closeButton.frame = NSRect(x: trailingX, y: centerY - 7, width: 14, height: 14)
        trailingStatusView.frame = closeButton.frame

        var paneStart = trailingX - 5
        if snapshot.paneCount > 1 {
            let countWidth = ceil((paneCountField.stringValue as NSString).size(
                withAttributes: [.font: Self.countFont]
            ).width)
            paneStart -= countWidth
            paneCountField.frame = NSRect(
                x: paneStart, y: centerY - 6, width: countWidth, height: 12
            )
            paneStart -= 2 + 9
            paneIconView.frame = NSRect(
                x: paneStart, y: centerY - 4.5, width: 9, height: 9
            )
            paneStart -= 5
        }

        titleField.frame = NSRect(
            x: x,
            y: centerY - 8,
            width: max(0, paneStart - x),
            height: 16
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let snapshot else { return }
        let fill: NSColor
        if snapshot.isSelected {
            fill = NSColor.labelColor.withAlphaComponent(0.09)
        } else if hovering {
            fill = NSColor.labelColor.withAlphaComponent(0.04)
        } else {
            return
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateHoverState()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateHoverState()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint else { return }
        if !dragging {
            let dx = event.locationInWindow.x - mouseDownPoint.x
            let dy = event.locationInWindow.y - mouseDownPoint.y
            guard hypot(dx, dy) >= 4 else { return }
            dragging = true
            delegate?.tabItemDidBeginDragging(id)
        }
        delegate?.tabItemDidDrag(id, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            dragging = false
        }
        if dragging {
            delegate?.tabItemDidEndDragging(id)
        } else {
            delegate?.tabItemDidSelect(id)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        delegate?.tabItemMenu(for: id)
    }

    /// Labels and symbols are presentation-only. Route their hit area back to
    /// the tab while leaving the visible close control independently clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if !closeButton.isHidden,
           hit === closeButton || hit.isDescendant(of: closeButton) {
            return closeButton
        }
        return self
    }

    override func accessibilityPerformPress() -> Bool {
        delegate?.tabItemDidSelect(id)
        return true
    }

    override func accessibilityPerformDelete() -> Bool {
        delegate?.tabItemDidClose(id)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = delegate?.tabItemMenu(for: id) else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
        return true
    }

    @objc private func close() {
        delegate?.tabItemDidClose(id)
    }

    private func updateHoverState() {
        closeButton.isHidden = !hovering
        trailingStatusView.isHidden = hovering
    }

    private func updateColors() {
        let selected = snapshot?.isSelected == true
        iconView.contentTintColor = selected ? Theme.cursor : .tertiaryLabelColor
        titleField.textColor = selected ? .labelColor : .secondaryLabelColor
        paneIconView.contentTintColor = .tertiaryLabelColor
        paneCountField.textColor = .tertiaryLabelColor
    }
}

@MainActor
private final class TabTrailingStatusView: NSView {
    var isDirty = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDirty else { return }
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: bounds.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)
        ).fill()
    }
}
