//
//  RecentCommitsView.swift
//  kero
//

import AppKit
import SwiftUI

/// A compact native commit graph embedded in the legacy Git panel. The
/// history rows stay AppKit-owned so expanding a large commit does not create
/// a SwiftUI view tree for every changed path.
struct RecentCommitsView: NSViewRepresentable {
    @Binding private var expandedCommitIDs: Set<String>
    @ObservedObject private var themeChanges = Theme.changes

    let commits: [GitStatusModel.RecentCommit]
    let fontScale: CGFloat
    let hasMoreCommits: Bool
    let isLoadingMore: Bool
    let loadMore: () -> Bool
    let openDiff: (
        _ commit: GitStatusModel.RecentCommit,
        _ file: GitStatusModel.RecentCommit.FileChange
    ) -> Void

    init(
        commits: [GitStatusModel.RecentCommit],
        expandedCommitIDs: Binding<Set<String>>,
        fontScale: CGFloat,
        hasMoreCommits: Bool,
        isLoadingMore: Bool,
        loadMore: @escaping () -> Bool,
        openDiff: @escaping (
            _ commit: GitStatusModel.RecentCommit,
            _ file: GitStatusModel.RecentCommit.FileChange
        ) -> Void
    ) {
        self.commits = commits
        _expandedCommitIDs = expandedCommitIDs
        self.fontScale = fontScale
        self.hasMoreCommits = hasMoreCommits
        self.isLoadingMore = isLoadingMore
        self.loadMore = loadMore
        self.openDiff = openDiff
    }

    func makeNSView(context: Context) -> RecentCommitsNSView {
        RecentCommitsNSView()
    }

    func updateNSView(_ view: RecentCommitsNSView, context: Context) {
        _ = themeChanges
        view.onToggleCommit = { id in
            if expandedCommitIDs.contains(id) {
                expandedCommitIDs.remove(id)
            } else {
                expandedCommitIDs.insert(id)
            }
        }
        view.onOpenDiff = openDiff
        view.onLoadMore = loadMore
        view.configure(
            commits: commits,
            expandedCommitIDs: expandedCommitIDs,
            fontScale: fontScale,
            hasMoreCommits: hasMoreCommits,
            isLoadingMore: isLoadingMore
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: RecentCommitsNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.requiredHeight)
    }
}

@MainActor
final class RecentCommitsNSView: NSView {
    private struct Snapshot: Equatable {
        let commits: [GitStatusModel.RecentCommit]
        let expandedCommitIDs: Set<String>
        let fontScale: CGFloat
        let hasMoreCommits: Bool
        let isLoadingMore: Bool
    }

    var onToggleCommit: ((String) -> Void)?
    var onLoadMore: (() -> Bool)?
    var onOpenDiff: ((
        GitStatusModel.RecentCommit,
        GitStatusModel.RecentCommit.FileChange
    ) -> Void)?
    private var snapshot: Snapshot?
    private var orderedRows: [NSView] = []
    private weak var observedClipView: NSClipView?
    private var autoLoadRequestPending = false
    private(set) var requiredHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: requiredHeight)
    }

    func configure(
        commits: [GitStatusModel.RecentCommit],
        expandedCommitIDs: Set<String>,
        fontScale: CGFloat,
        hasMoreCommits: Bool,
        isLoadingMore: Bool
    ) {
        let next = Snapshot(
            commits: commits,
            expandedCommitIDs: expandedCommitIDs,
            fontScale: fontScale,
            hasMoreCommits: hasMoreCommits,
            isLoadingMore: isLoadingMore
        )
        guard snapshot != next else {
            orderedRows.forEach { $0.needsDisplay = true }
            evaluateAutoLoadIfNeeded()
            return
        }
        if snapshot?.commits.count != next.commits.count
            || snapshot?.isLoadingMore != next.isLoadingMore
            || !next.hasMoreCommits {
            autoLoadRequestPending = false
        }
        snapshot = next
        rebuildRows(using: next)
    }

    private func rebuildRows(using snapshot: Snapshot) {
        orderedRows.forEach { $0.removeFromSuperview() }
        orderedRows.removeAll(keepingCapacity: true)

        let metrics = CommitGraphMetrics(fontScale: snapshot.fontScale)
        for (commitIndex, commit) in snapshot.commits.enumerated() {
            let isExpanded = snapshot.expandedCommitIDs.contains(commit.id)
            let isLastCommit = commitIndex == snapshot.commits.count - 1
            let row = CommitGraphRowView(
                commit: commit,
                isFirst: commitIndex == 0,
                continuesBelow: isExpanded || !isLastCommit,
                isExpanded: isExpanded,
                metrics: metrics
            )
            row.onToggle = { [weak self] id in self?.onToggleCommit?(id) }
            addArrangedRow(row)

            guard isExpanded else { continue }
            if commit.files.isEmpty {
                addArrangedRow(CommitFileRowView(
                    change: nil,
                    continuesBelow: !isLastCommit,
                    metrics: metrics,
                    onOpen: nil
                ))
            } else {
                for (fileIndex, file) in commit.files.enumerated() {
                    addArrangedRow(CommitFileRowView(
                        change: file,
                        continuesBelow: fileIndex < commit.files.count - 1 || !isLastCommit,
                        metrics: metrics,
                        onOpen: { [weak self] in self?.onOpenDiff?(commit, file) }
                    ))
                }
            }
        }
        requiredHeight = orderedRows.reduce(0) { $0 + $1.intrinsicContentSize.height }
        invalidateIntrinsicContentSize()
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollObservation()
            self?.evaluateAutoLoadIfNeeded()
        }
    }

    private func addArrangedRow(_ row: NSView) {
        addSubview(row)
        orderedRows.append(row)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in orderedRows {
            let height = row.intrinsicContentSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
        updateScrollObservation()
        evaluateAutoLoadIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollObservation()
            self?.evaluateAutoLoadIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScrollObservation()
        evaluateAutoLoadIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        orderedRows.forEach { $0.needsDisplay = true }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The history view lives inside the Git panel's existing SwiftUI scroll
    /// view. Observe its native clip view so reaching the last couple of rows
    /// requests another page without adding a SwiftUI sentinel or button.
    private func updateScrollObservation() {
        let clipView = enclosingScrollView?.contentView
        guard observedClipView !== clipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = clipView
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func scrollBoundsDidChange() {
        evaluateAutoLoadIfNeeded()
    }

    private func evaluateAutoLoadIfNeeded() {
        guard let snapshot,
              snapshot.hasMoreCommits,
              !snapshot.isLoadingMore,
              !autoLoadRequestPending,
              requiredHeight > 0,
              let clipView = observedClipView ?? enclosingScrollView?.contentView else { return }
        let visibleRect = convert(clipView.bounds, from: clipView)
        let preloadDistance = max(44, clipView.bounds.height * 0.25)
        guard visibleRect.minY < requiredHeight,
              visibleRect.maxY >= requiredHeight - preloadDistance else { return }
        // Only latch requests the model accepted. A temporary rejection (for
        // example while a Git mutation is finishing) must remain retryable on
        // the next SwiftUI update or scroll/layout event.
        autoLoadRequestPending = onLoadMore?() == true
    }
}

@MainActor
private struct CommitGraphMetrics {
    let scale: CGFloat
    let commitHeight: CGFloat
    let fileHeight: CGFloat
    let subjectFont: NSFont
    let metadataFont: NSFont
    let fileFont: NSFont
    let pathFont: NSFont
    let statusFont: NSFont

    init(fontScale: CGFloat) {
        scale = fontScale
        commitHeight = max(22, (26 * fontScale).rounded(.up))
        fileHeight = max(20, (23 * fontScale).rounded(.up))
        subjectFont = .systemFont(ofSize: 11.5 * fontScale, weight: .regular)
        metadataFont = .systemFont(ofSize: 9.5 * fontScale, weight: .medium)
        fileFont = .systemFont(ofSize: 11 * fontScale, weight: .regular)
        pathFont = .systemFont(ofSize: 9.5 * fontScale, weight: .regular)
        statusFont = .monospacedSystemFont(ofSize: 9.5 * fontScale, weight: .semibold)
    }

    var graphX: CGFloat { 14 }
    var contentX: CGFloat { 27 }
    var nestedRailX: CGFloat { 35 }
    var fileIconX: CGFloat { 45 }
    var fileContentX: CGFloat { 61 }
}

@MainActor
private final class CommitGraphRowView: NSView {
    let commit: GitStatusModel.RecentCommit
    let isFirst: Bool
    let continuesBelow: Bool
    let isExpanded: Bool
    let metrics: CommitGraphMetrics
    var onToggle: ((String) -> Void)?

    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    init(
        commit: GitStatusModel.RecentCommit,
        isFirst: Bool,
        continuesBelow: Bool,
        isExpanded: Bool,
        metrics: CommitGraphMetrics
    ) {
        self.commit = commit
        self.isFirst = isFirst
        self.continuesBelow = continuesBelow
        self.isExpanded = isExpanded
        self.metrics = metrics
        super.init(frame: .zero)
        focusRingType = .default
        toolTip = "\(commit.shortHash) · \(commit.author) · \(commit.relativeDate)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            localized: "\(commit.subject), \(commit.shortHash), by \(commit.author), \(commit.relativeDate)",
            comment: "Commit summary, short hash, author, and relative date for accessibility."
        ))
        setAccessibilityHelp(String(localized: "Shows files changed in this commit"))
        setAccessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.commitHeight)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 1) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        synchronizeHoverWithMouse()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onToggle?(commit.id)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onToggle?(commit.id)
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?(commit.id)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy Commit Hash"), action: #selector(copyHash), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Copy Commit Message"), action: #selector(copyMessage), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func copyHash() { copyToPasteboard(commit.hash) }
    @objc private func copyMessage() { copyToPasteboard(commit.subject) }

    private func synchronizeHoverWithMouse() {
        guard let window else {
            setHovered(false)
            return
        }
        setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isExpanded {
            Theme.accent.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 4, yRadius: 4).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 4, yRadius: 4).fill()
        }

        drawGraph()
        drawSummary()
    }

    private func drawGraph() {
        let centerY = bounds.midY
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.move(to: NSPoint(x: metrics.graphX, y: isFirst ? centerY : 0))
        line.line(to: NSPoint(x: metrics.graphX, y: continuesBelow ? bounds.maxY : centerY))
        Theme.accent.withAlphaComponent(0.72).setStroke()
        line.stroke()

        Theme.accent.setFill()
        let radius: CGFloat = isExpanded ? 5 : 4
        NSBezierPath(
            ovalIn: NSRect(
                x: metrics.graphX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
        ).fill()
    }

    private func drawSummary() {
        let reference = primaryReference
        let badgeWidth = reference.map(referenceBadgeWidth) ?? 0
        let trailingInset: CGFloat = 6
        if let reference {
            drawReferenceBadge(reference, width: badgeWidth)
        }

        let summary = NSMutableAttributedString(
            string: commit.subject,
            attributes: [
                .font: metrics.subjectFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        summary.append(NSAttributedString(
            string: "  " + commit.author.uppercased(),
            attributes: [
                .font: metrics.metadataFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        ))
        let height = ceil(max(metrics.subjectFont.pointSize, metrics.metadataFont.pointSize) * 1.45)
        summary.draw(
            with: NSRect(
                x: metrics.contentX,
                y: (bounds.height - height) / 2,
                width: max(0, bounds.width - metrics.contentX - badgeWidth - trailingInset),
                height: height
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
    }

    private var primaryReference: String? {
        commit.references.first {
            $0.contains("/") && !$0.hasPrefix("HEAD -> ") && !$0.contains("/HEAD")
        } ?? commit.references.first.map {
            $0.hasPrefix("HEAD -> ") ? String($0.dropFirst("HEAD -> ".count)) : $0
        }
    }

    private func referenceBadgeWidth(_ reference: String) -> CGFloat {
        min(104, ceil((reference as NSString).size(withAttributes: [.font: metrics.metadataFont]).width) + 14)
    }

    private func drawReferenceBadge(_ reference: String, width: CGFloat) {
        let height = max(16, ceil(metrics.metadataFont.pointSize + 6))
        let rect = NSRect(
            x: bounds.width - width - 4,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        Theme.accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        (reference as NSString).draw(
            with: rect.insetBy(dx: 7, dy: (height - metrics.metadataFont.pointSize * 1.35) / 2),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: metrics.metadataFont,
                .foregroundColor: NSColor.white,
            ],
            context: nil
        )
    }
}

@MainActor
private final class CommitFileRowView: NSView {
    let change: GitStatusModel.RecentCommit.FileChange?
    let continuesBelow: Bool
    let metrics: CommitGraphMetrics
    let onOpen: (() -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    init(
        change: GitStatusModel.RecentCommit.FileChange?,
        continuesBelow: Bool,
        metrics: CommitGraphMetrics,
        onOpen: (() -> Void)?
    ) {
        self.change = change
        self.continuesBelow = continuesBelow
        self.metrics = metrics
        self.onOpen = onOpen
        super.init(frame: .zero)
        if let change {
            toolTip = change.path
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(change.fileName), \(statusName(for: change.status)), \(change.path)")
            setAccessibilityHelp(String(localized: "Opens changes"))
        } else {
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(String(localized: "No changed files"))
        }
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { change != nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.fileHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        synchronizeHoverWithMouse()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard change != nil else { return }
        window?.makeFirstResponder(self)
        onOpen?()
    }

    override func keyDown(with event: NSEvent) {
        if change != nil, event.keyCode == 36 || event.keyCode == 49 {
            onOpen?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard change != nil else { return false }
        onOpen?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard change != nil else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(
            withTitle: String(localized: "Copy Relative Path"),
            action: #selector(copyPath),
            keyEquivalent: ""
        )
        item.target = self
        return menu
    }

    @objc private func copyPath() {
        if let change { copyToPasteboard(change.path) }
    }

    private func synchronizeHoverWithMouse() {
        guard let window else {
            setHovered(false)
            return
        }
        setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.055).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: metrics.nestedRailX + 5,
                    y: 1,
                    width: max(0, bounds.width - metrics.nestedRailX - 7),
                    height: max(0, bounds.height - 2)
                ),
                xRadius: 4,
                yRadius: 4
            ).fill()
        }
        drawRails()
        guard let change else {
            drawEmptyState()
            return
        }
        drawFile(change)
    }

    private func drawRails() {
        let graph = NSBezierPath()
        graph.lineWidth = 1.5
        graph.move(to: NSPoint(x: metrics.graphX, y: 0))
        graph.line(to: NSPoint(x: metrics.graphX, y: continuesBelow ? bounds.maxY : bounds.midY))
        Theme.accent.withAlphaComponent(0.72).setStroke()
        graph.stroke()

        let nested = NSBezierPath()
        nested.lineWidth = 1
        nested.move(to: NSPoint(x: metrics.nestedRailX, y: 0))
        nested.line(to: NSPoint(x: metrics.nestedRailX, y: bounds.maxY))
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        nested.stroke()
    }

    private func drawFile(_ change: GitStatusModel.RecentCommit.FileChange) {
        let statusWidth: CGFloat = 18
        let symbolRect = NSRect(
            x: metrics.fileIconX,
            y: (bounds.height - 12) / 2,
            width: 12,
            height: 12
        )
        MaterialFileIcon.image(forPath: change.path, appearance: effectiveAppearance).draw(
            in: symbolRect,
            from: .zero,
            operation: .sourceOver,
            fraction: change.status == "D" ? 0.6 : 1
        )

        let text = NSMutableAttributedString(
            string: change.fileName,
            attributes: [
                .font: metrics.fileFont,
                .foregroundColor: NSColor.labelColor,
                .strikethroughStyle: change.status == "D" ? NSUnderlineStyle.single.rawValue : 0,
            ]
        )
        if !change.directory.isEmpty {
            text.append(NSAttributedString(
                string: "  " + change.directory,
                attributes: [
                    .font: metrics.pathFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            ))
        }
        let height = ceil(max(metrics.fileFont.pointSize, metrics.pathFont.pointSize) * 1.45)
        text.draw(
            with: NSRect(
                x: metrics.fileContentX,
                y: (bounds.height - height) / 2,
                width: max(0, bounds.width - metrics.fileContentX - statusWidth - 5),
                height: height
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )

        (String(change.status) as NSString).draw(
            with: NSRect(
                x: bounds.width - statusWidth - 3,
                y: (bounds.height - height) / 2,
                width: statusWidth,
                height: height
            ),
            options: [.usesLineFragmentOrigin],
            attributes: [
                .font: metrics.statusFont,
                .foregroundColor: statusColor(for: change.status),
            ],
            context: nil
        )
    }

    private func drawEmptyState() {
        let text = String(localized: "No changed files") as NSString
        let height = ceil(metrics.pathFont.pointSize * 1.45)
        text.draw(
            in: NSRect(
                x: metrics.fileContentX,
                y: (bounds.height - height) / 2,
                width: max(0, bounds.width - metrics.fileContentX - 5),
                height: height
            ),
            withAttributes: [
                .font: metrics.pathFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func statusName(for status: Character) -> String {
    switch status {
    case "M": String(localized: "Modified")
    case "A": String(localized: "Added")
    case "D": String(localized: "Deleted")
    case "R": String(localized: "Renamed")
    case "C": String(localized: "Copied")
    case "U": String(localized: "Conflict")
    default: String(localized: "Changed")
    }
}

private func statusColor(for status: Character) -> NSColor {
    switch status {
    case "M": NSColor(srgbRed: 0.82, green: 0.60, blue: 0.13, alpha: 1)
    case "A": NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)
    case "D": NSColor(srgbRed: 1.0, green: 0.48, blue: 0.45, alpha: 1)
    case "R", "C": NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1)
    case "U": NSColor(srgbRed: 0.74, green: 0.55, blue: 1.0, alpha: 1)
    default: .secondaryLabelColor
    }
}
