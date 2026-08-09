//
//  TabSwitcherView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Owns the press-and-hold Ctrl-Tab interaction for one window. Repeated Tab
/// presses move only the highlighted card; the project's real selection stays
/// untouched until Control is released. Escape cancels the provisional choice.
@MainActor
final class TabSwitcherController: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var highlightedTabID: UUID?
    @Published private(set) var terminalPreviews: [UUID: String] = [:]
    /// Recency order captured when the switcher opened, frozen for the whole
    /// gesture so cards never reshuffle under the highlight.
    @Published private(set) var orderedTabIDs: [UUID] = []

    private weak var activeProject: Project?
    private var originalTabID: UUID?
    private var previewTask: Task<Void, Never>?
    private var isConsumingTabKey = false
    private var isConsumingEscapeKey = false
    private var acceptsPointerHighlight = false

    /// Returns nil for an event consumed by the switcher.
    func handle(_ event: NSEvent, manager: TerminalManager) -> NSEvent? {
        switch event.type {
        case .mouseMoved:
            // AppKit sends mouseEntered when a tracking area is created under
            // a stationary pointer. Wait for actual pointer movement before
            // allowing hover to replace the keyboard-selected card.
            acceptsPointerHighlight = isPresented
            return event

        case .flagsChanged:
            guard isPresented, !event.modifierFlags.contains(.control) else {
                return event
            }
            finish()
            return nil

        case .keyUp:
            if event.keyCode == 48, isConsumingTabKey {
                isConsumingTabKey = false
                return nil
            }
            if event.keyCode == 53, isConsumingEscapeKey {
                isConsumingEscapeKey = false
                return nil
            }
            return event

        case .keyDown:
            if isPresented, event.keyCode == 53 {
                isConsumingEscapeKey = true
                cancel()
                return nil
            }

            guard event.keyCode == 48 else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control),
                  flags.isDisjoint(with: [.command, .option])
            else {
                // Do not let a missed key-up from an interrupted switcher
                // consume a later ordinary Tab press.
                isConsumingTabKey = false
                return event
            }

            guard cycle(in: manager, reverse: flags.contains(.shift)) else {
                return event
            }
            isConsumingTabKey = true
            return nil

        default:
            return event
        }
    }

    /// Commit the highlighted tab on Control release and close the overlay.
    func finish() {
        dismiss(commitSelection: true)
    }

    /// Close the overlay without changing the selected tab.
    func cancel() {
        dismiss(commitSelection: false)
    }

    private func dismiss(commitSelection: Bool) {
        if commitSelection,
           let project = activeProject,
           project.selectedTabID == originalTabID,
           let highlightedTabID,
           project.tabs.contains(where: { $0.id == highlightedTabID }) {
            project.selectedTabID = highlightedTabID
        }
        previewTask?.cancel()
        previewTask = nil
        withAnimation(.easeOut(duration: 0.12)) {
            isPresented = false
        }
        highlightedTabID = nil
        originalTabID = nil
        activeProject = nil
        acceptsPointerHighlight = false
    }

    func select(_ tabID: UUID, in project: Project) {
        guard project.tabs.contains(where: { $0.id == tabID }) else { return }
        project.selectedTabID = tabID
        dismiss(commitSelection: false)
    }

    func highlight(_ tabID: UUID, in project: Project) {
        guard acceptsPointerHighlight,
              isPresented,
              activeProject === project,
              highlightedTabID != tabID,
              project.tabs.contains(where: { $0.id == tabID })
        else { return }
        highlightedTabID = tabID
    }

    /// The tabs the overlay draws, in the order this gesture walks them.
    func orderedTabs(in project: Project) -> [PaneTab] {
        let ordered = orderedTabIDs.compactMap { id in
            project.tabs.first { $0.id == id }
        }
        return ordered.isEmpty ? project.tabs : ordered
    }

    private func cycle(in manager: TerminalManager, reverse: Bool) -> Bool {
        guard let project = manager.selectedProject,
              project.tabs.count > 1,
              let selectedID = project.selectedTabID
        else { return false }

        if !isPresented || activeProject !== project {
            previewTask?.cancel()
            activeProject = project
            originalTabID = selectedID
            orderedTabIDs = project.tabsByRecency.map(\.id)
            // Open already pointing at the previously used tab, so one
            // Ctrl-Tab toggles between the last two tabs like Cmd-Tab does.
            highlightedTabID = orderedTabIDs[reverse ? orderedTabIDs.count - 1 : 1]
            acceptsPointerHighlight = false
            let validContentIDs = Set(project.tabs.flatMap(\.allContents).map(\.id))
            terminalPreviews = terminalPreviews.filter {
                validContentIDs.contains($0.key)
            }
            withAnimation(.easeOut(duration: 0.12)) {
                isPresented = true
            }
            refreshTerminalPreviews(in: project)
            return true
        }

        let order = orderedTabs(in: project).map(\.id)
        guard let currentHighlightedTabID = highlightedTabID,
              let currentIndex = order.firstIndex(of: currentHighlightedTabID)
        else {
            cancel()
            return false
        }
        let offset = reverse ? -1 : 1
        highlightedTabID = order[(currentIndex + offset + order.count) % order.count]
        return true
    }

    /// Terminal surfaces are Metal-backed, so AppKit bitmap caching produces
    /// black cards. Ask the backend for plain visible output instead,
    /// recapturing every terminal once when the switcher opens. Non-terminal
    /// cards are rendered directly from their models.
    private func refreshTerminalPreviews(in project: Project) {
        previewTask?.cancel()
        let sessions = project.tabs.flatMap(\.sessions)
        guard !sessions.isEmpty else { return }

        previewTask = Task { @MainActor [weak self] in
            // Let SwiftUI present the switcher before doing synchronous surface
            // exports. Split tabs are captured one pane per run-loop turn.
            await Task.yield()
            for session in sessions {
                guard !Task.isCancelled, let self, self.isPresented else { return }
                if let preview = TerminalHistorySerializer.previewText(
                    from: session.surface,
                    maxLines: 28,
                    maxColumns: 140
                ), self.terminalPreviews[session.id] != preview {
                    self.terminalPreviews[session.id] = preview
                }
                await Task.yield()
            }
        }
    }
}

/// Installs a window-scoped local event monitor. A regular SwiftUI
/// `keyboardShortcut` cannot observe the Control key being released, which is
/// the gesture that commits a Cmd-Tab-style switch.
struct TabSwitcherEventMonitor: NSViewRepresentable {
    let manager: TerminalManager
    let controller: TabSwitcherController

    func makeNSView(context: Context) -> TabSwitcherMonitorView {
        let view = TabSwitcherMonitorView()
        view.manager = manager
        view.controller = controller
        return view
    }

    func updateNSView(_ view: TabSwitcherMonitorView, context: Context) {
        view.manager = manager
        view.controller = controller
    }

    static func dismantleNSView(
        _ view: TabSwitcherMonitorView, coordinator: ()
    ) {
        view.detach()
    }
}

@MainActor
final class TabSwitcherMonitorView: NSView {
    weak var manager: TerminalManager?
    weak var controller: TabSwitcherController?

    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .mouseMoved]
        ) { [weak self, weak window] event in
            // AppKit invokes local monitors synchronously on the event thread
            // (the main thread). Wrap the non-Sendable NSEvent only across
            // `assumeMainActor`'s generic boundary; it never changes threads.
            let input = MainThreadEvent(event)
            let output: MainThreadEvent = assumeMainActor {
                guard let self,
                      let window,
                      window.isKeyWindow,
                      let manager = self.manager,
                      let controller = self.controller,
                      let event = input.value
                else { return input }
                return MainThreadEvent(
                    controller.handle(event, manager: manager)
                )
            }
            return output.value
        }

        for name in [
            NSWindow.didResignKeyNotification,
            NSApplication.didResignActiveNotification,
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: name == NSWindow.didResignKeyNotification ? window : nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelFromMainThreadNotification()
            })
        }
    }

    nonisolated private func cancelFromMainThreadNotification() {
        assumeMainActor {
            controller?.cancel()
        }
    }

    func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// `NSEvent` is explicitly non-Sendable, but a local event monitor and its
/// result are synchronous on AppKit's main event thread.
private struct MainThreadEvent: @unchecked Sendable {
    let value: NSEvent?

    init(_ value: NSEvent?) {
        self.value = value
    }
}

private enum TabSwitcherLayout {
    static let cardWidth: CGFloat = 194
    static let cardHeight: CGFloat = 169
    static let cardInset: CGFloat = 9
    static let cardBottomInset: CGFloat = 14
    static let previewWidth: CGFloat = 176
    static let previewHeight: CGFloat = 119
    static let previewTitleSpacing: CGFloat = 9
    static let gridInset: CGFloat = 8
    static let gridSpacing: CGFloat = 0
    static let previewCornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 16
    static let containerCornerRadius: CGFloat = 26
}

/// Centered switcher chrome: a vertically scrolling thumbnail grid with at
/// most five tabs per row and the current candidate kept in view.
struct TabSwitcherOverlay: View {
    @ObservedObject var project: Project
    @ObservedObject var controller: TabSwitcherController
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let tabs = controller.orderedTabs(in: project)
            let columnCount = columnsPerRow(count: tabs.count, available: geometry.size.width)

            ZStack {
                Color.clear
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: gridColumns(count: columnCount),
                            alignment: .leading,
                            spacing: TabSwitcherLayout.gridSpacing
                        ) {
                            ForEach(tabs, id: \.id) { tab in
                                TabSwitcherCard(
                                    tab: tab,
                                    index: project.tabs.firstIndex { $0.id == tab.id } ?? 0,
                                    isHighlighted: tab.id == controller.highlightedTabID,
                                    terminalPreviews: controller.terminalPreviews,
                                    highlight: {
                                        controller.highlight(tab.id, in: project)
                                    },
                                    select: {
                                        controller.select(tab.id, in: project)
                                    }
                                )
                                .id(tab.id)
                            }
                        }
                        .padding(TabSwitcherLayout.gridInset)
                    }
                    .frame(
                        width: overlayWidth(columns: columnCount),
                        height: gridHeight(
                            count: tabs.count,
                            columns: columnCount,
                            available: geometry.size.height
                        )
                    )
                    .onAppear {
                        guard let id = controller.highlightedTabID else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChange(of: controller.highlightedTabID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .background {
                    containerBackground
                        .clipShape(RoundedRectangle(
                            cornerRadius: TabSwitcherLayout.containerCornerRadius,
                            style: .continuous
                        ))
                        .shadow(
                            color: .black.opacity(colorScheme == .light ? 0.18 : 0.28),
                            radius: 24,
                            y: 10
                        )
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: TabSwitcherLayout.containerCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        containerBorderColor,
                        lineWidth: colorScheme == .light ? 0.5 : 1.5
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tab switcher")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    @ViewBuilder
    private var containerBackground: some View {
        if colorScheme == .light {
            // Dia's light switcher is effectively opaque: a warm, subtly
            // violet white that stays legible over both light and dark tabs.
            Color(red: 0.981, green: 0.979, blue: 0.985)
        } else {
            Color(nsColor: Theme.background)
        }
    }

    private var containerBorderColor: Color {
        colorScheme == .light
            ? .black.opacity(0.28)
            : .primary.opacity(0.18)
    }

    private func columnsPerRow(count: Int, available: CGFloat) -> Int {
        let horizontalInsets = 44 + TabSwitcherLayout.gridInset * 2
        let usable = max(
            TabSwitcherLayout.cardWidth,
            available - horizontalInsets
        )
        let fitting = Int(usable / TabSwitcherLayout.cardWidth)
        return min(5, max(1, min(count, fitting)))
    }

    private func gridColumns(count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(TabSwitcherLayout.cardWidth),
                spacing: TabSwitcherLayout.gridSpacing
            ),
            count: count
        )
    }

    private func overlayWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * TabSwitcherLayout.cardWidth
            + TabSwitcherLayout.gridInset * 2
    }

    private func gridHeight(count: Int, columns: Int, available: CGFloat) -> CGFloat {
        let rows = (count + columns - 1) / columns
        let contentHeight = CGFloat(rows) * TabSwitcherLayout.cardHeight
            + TabSwitcherLayout.gridInset * 2
        return min(
            contentHeight,
            max(
                TabSwitcherLayout.cardHeight + TabSwitcherLayout.gridInset * 2,
                available - 44
            )
        )
    }
}

private struct TabSwitcherCard: View {
    @ObservedObject var tab: PaneTab
    let index: Int
    let isHighlighted: Bool
    let terminalPreviews: [UUID: String]
    let highlight: () -> Void
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: TabSwitcherLayout.previewTitleSpacing) {
            TabThumbnail(tab: tab, terminalPreviews: terminalPreviews)
                .frame(
                    width: TabSwitcherLayout.previewWidth,
                    height: TabSwitcherLayout.previewHeight
                )
                .clipShape(RoundedRectangle(
                    cornerRadius: TabSwitcherLayout.previewCornerRadius,
                    style: .continuous
                ))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: TabSwitcherLayout.previewCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                }

            HStack(spacing: 8) {
                titleIcon
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary.opacity(isHighlighted ? 1 : 0.82))
                Text(verbatim: tab.displayTitle ?? String(localized: "Tab \(index + 1)"))
                    .font(.system(
                        size: 14,
                        weight: .medium
                    ))
                    .foregroundStyle(.primary.opacity(isHighlighted ? 1 : 0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if tab.focusedContent?.isDirty == true {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, TabSwitcherLayout.cardInset)
        .padding(.top, TabSwitcherLayout.cardInset)
        .padding(.bottom, TabSwitcherLayout.cardBottomInset)
        .frame(
            width: TabSwitcherLayout.cardWidth,
            height: TabSwitcherLayout.cardHeight,
            alignment: .topLeading
        )
        .background {
            if isHighlighted {
                RoundedRectangle(
                    cornerRadius: TabSwitcherLayout.cardCornerRadius,
                    style: .continuous
                )
                .fill(highlightedBackground)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHighlighted)
        .overlay {
            TabSwitcherInteractionView(
                onEnter: highlight,
                onClick: select
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                localized: "Tab \(index + 1), \(tab.displayTitle ?? String(localized: "Untitled"))",
                comment: "Accessibility label for a tab. The placeholders are its position and title."
            )
        )
        .accessibilityValue(isHighlighted ? "Selected on release" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityAction { select() }
    }

    @ViewBuilder
    private var titleIcon: some View {
        if case .browser(let browser) = tab.focusedContent {
            BrowserFaviconView(browser: browser, size: 16)
        } else if let path = tab.focusedContent?.fileIconPath {
            MaterialFileIconView(path: path, size: 16)
        } else {
            Image(systemName: tab.focusedContent?.systemImage ?? "rectangle")
        }
    }

    private var highlightedBackground: Color {
        colorScheme == .light
            ? Color(red: 0.838, green: 0.835, blue: 0.841)
            : Color.primary.opacity(0.20)
    }
}

private struct TabSwitcherInteractionView: NSViewRepresentable {
    let onEnter: () -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> TabSwitcherInteractionNSView {
        let view = TabSwitcherInteractionNSView()
        view.onEnter = onEnter
        view.onClick = onClick
        return view
    }

    func updateNSView(
        _ view: TabSwitcherInteractionNSView,
        context: Context
    ) {
        view.onEnter = onEnter
        view.onClick = onClick
    }
}

@MainActor
private final class TabSwitcherInteractionNSView: NSView {
    var onEnter: (() -> Void)?
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func mouseMoved(with event: NSEvent) {
        onEnter?()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick?()
        }
    }
}

/// A small but structurally faithful rendering of a tab. The recursive split
/// geometry is preserved; each pane supplies a backend-independent preview.
private struct TabThumbnail: View {
    @ObservedObject var tab: PaneTab
    let terminalPreviews: [UUID: String]

    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            if tab.isZoomed, let pane = tab.focusedPane {
                TabPaneThumbnail(
                    content: pane.content,
                    terminalPreview: terminalPreviews[pane.content.id]
                )
            } else {
                let placements = tab.layout.geometry(
                    in: CGRect(origin: .zero, size: geometry.size), gap: gap
                ).panes
                ZStack(alignment: .topLeading) {
                    ForEach(placements) { placement in
                        TabPaneThumbnail(
                            content: placement.pane.content,
                            terminalPreview: terminalPreviews[
                                placement.pane.content.id
                            ]
                        )
                        .frame(
                            width: placement.frame.width,
                            height: placement.frame.height
                        )
                        .offset(
                            x: placement.frame.minX,
                            y: placement.frame.minY
                        )
                    }
                }
            }
        }
        .background(Color(nsColor: Theme.background))
    }
}

private struct TabPaneThumbnail: View {
    let content: PaneContent
    let terminalPreview: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch content {
            case .session(let session):
                terminal(session)
            case .file(let file):
                filePreview(file)
            case .browser(let browser):
                browserPreview(browser)
            case .diff(let diff):
                diffPreview(diff)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
        .clipped()
    }

    @ViewBuilder
    private func terminal(_ session: TerminalSession) -> some View {
        if let terminalPreview, !terminalPreview.isEmpty {
            Text(terminalPreview)
                .font(.system(size: 5.2, design: .monospaced))
                .foregroundStyle(Color(nsColor: terminalForeground))
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(5)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color(nsColor: Theme.accent))
                Text(session.title)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                Text(session.currentDirectoryPath)
                    .font(.system(size: 5.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func filePreview(_ file: FileTab) -> some View {
        switch file.content {
        case .text:
            Text(textExcerpt(file.text, aroundUTF16: file.editorState.selectionLocation))
                .font(.system(size: 5.2, design: .monospaced))
                .foregroundStyle(Color(nsColor: terminalForeground))
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(5)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(5)
        case .unavailable(let reason):
            VStack(spacing: 4) {
                MaterialFileIconView(path: file.path, size: 18, opacity: 0.82)
                Text(reason)
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(6)
        }
    }

    private func diffPreview(_ diff: DiffTab) -> some View {
        HStack(spacing: 1) {
            Text(textExcerpt(diff.web.oldContent))
                .foregroundStyle(Color.red.opacity(0.76))
                .background(Color.red.opacity(0.07))
            Text(textExcerpt(diff.web.newContent))
                .foregroundStyle(Color.green.opacity(0.76))
                .background(Color.green.opacity(0.07))
        }
        .font(.system(size: 4.5, design: .monospaced))
        .lineSpacing(0)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
    }

    private func browserPreview(_ browser: BrowserTab) -> some View {
        BrowserTabSwitcherPreview(browser: browser)
    }

    private var terminalForeground: NSColor {
        Theme.terminal(dark: colorScheme == .dark).foregroundNSColor
    }

    /// Bound the sampled UTF-16 range before splitting it into lines so a
    /// multi-megabyte editor or diff cannot make a tiny thumbnail expensive.
    private func textExcerpt(
        _ text: String, aroundUTF16 location: Int? = nil
    ) -> String {
        let source = text as NSString
        guard source.length > 0 else { return "" }

        let center = min(max(0, location ?? 0), source.length)
        let start = max(0, center - (location == nil ? 0 : 1_200))
        let length = min(7_000, source.length - start)
        var sample = source.substring(with: NSRange(location: start, length: length))
        if start > 0, let newline = sample.firstIndex(of: "\n") {
            sample.removeSubrange(...newline)
        }

        let lines = sample
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(26)
            .map { String($0.prefix(120)) }
        return lines.joined(separator: "\n")
    }
}

private struct BrowserTabSwitcherPreview: View {
    @ObservedObject var browser: BrowserTab

    var body: some View {
        VStack(spacing: 5) {
            BrowserFaviconView(
                browser: browser,
                size: 18,
                fallbackSystemImage: browser.isLoading
                    ? "globe.americas.fill"
                    : "globe"
            )
            .font(.system(size: 17, weight: .light))
            .foregroundStyle(Color(nsColor: Theme.accent))
            Text(browser.title)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
            if !browser.urlString.isEmpty {
                Text(browser.urlString)
                    .font(.system(size: 5.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(6)
    }
}
