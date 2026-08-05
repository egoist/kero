//
//  WorktreesSectionView.swift
//  kero
//

import AppKit
import SwiftUI

/// Native worktree navigation embedded in the legacy SwiftUI Git panel.
/// Rows intentionally open parallel Kero projects instead of mutating the
/// current terminal or checkout.
struct WorktreesSectionView: NSViewRepresentable {
    @Binding private var isCollapsed: Bool
    @ObservedObject private var themeChanges = Theme.changes

    let worktrees: [GitStatusModel.Worktree]
    let currentPath: String
    let sessionCounts: [String: Int]
    let fontScale: CGFloat
    let openWorktree: (GitStatusModel.Worktree) -> Void

    init(
        worktrees: [GitStatusModel.Worktree],
        currentPath: String,
        sessionCounts: [String: Int],
        fontScale: CGFloat,
        isCollapsed: Binding<Bool>,
        openWorktree: @escaping (GitStatusModel.Worktree) -> Void
    ) {
        self.worktrees = worktrees
        self.currentPath = currentPath
        self.sessionCounts = sessionCounts
        self.fontScale = fontScale
        _isCollapsed = isCollapsed
        self.openWorktree = openWorktree
    }

    func makeNSView(context: Context) -> WorktreesSectionNSView {
        WorktreesSectionNSView()
    }

    func updateNSView(_ view: WorktreesSectionNSView, context: Context) {
        _ = themeChanges
        view.onToggleCollapsed = { isCollapsed.toggle() }
        view.onOpenWorktree = openWorktree
        view.configure(
            worktrees: worktrees,
            currentPath: currentPath,
            sessionCounts: sessionCounts,
            fontScale: fontScale,
            isCollapsed: isCollapsed
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: WorktreesSectionNSView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.requiredHeight)
    }
}

@MainActor
final class WorktreesSectionNSView: NSView {
    private struct Snapshot: Equatable {
        let worktrees: [GitStatusModel.Worktree]
        let currentPath: String
        let sessionCounts: [String: Int]
        let fontScale: CGFloat
        let isCollapsed: Bool
    }

    var onToggleCollapsed: (() -> Void)?
    var onOpenWorktree: ((GitStatusModel.Worktree) -> Void)?

    private var snapshot: Snapshot?
    private var orderedRows: [NSView] = []
    private(set) var requiredHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: requiredHeight)
    }

    func configure(
        worktrees: [GitStatusModel.Worktree],
        currentPath: String,
        sessionCounts: [String: Int],
        fontScale: CGFloat,
        isCollapsed: Bool
    ) {
        let normalizedCurrentPath = Self.normalizedPath(currentPath)
        let sortedWorktrees = worktrees.sorted { lhs, rhs in
            let lhsCurrent = Self.normalizedPath(lhs.path) == normalizedCurrentPath
            let rhsCurrent = Self.normalizedPath(rhs.path) == normalizedCurrentPath
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            let lhsOpen = sessionCounts[lhs.path, default: 0] > 0
            let rhsOpen = sessionCounts[rhs.path, default: 0] > 0
            if lhsOpen != rhsOpen { return lhsOpen }
            return Self.title(for: lhs).localizedStandardCompare(Self.title(for: rhs))
                == .orderedAscending
        }
        let next = Snapshot(
            worktrees: sortedWorktrees,
            currentPath: normalizedCurrentPath,
            sessionCounts: sessionCounts,
            fontScale: fontScale,
            isCollapsed: isCollapsed
        )
        guard snapshot != next else {
            orderedRows.forEach { $0.needsDisplay = true }
            return
        }
        snapshot = next
        rebuildRows(using: next)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in orderedRows {
            let height = row.intrinsicContentSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        orderedRows.forEach { $0.needsDisplay = true }
    }

    private func rebuildRows(using snapshot: Snapshot) {
        orderedRows.forEach { $0.removeFromSuperview() }
        orderedRows.removeAll(keepingCapacity: true)

        let metrics = WorktreeMetrics(fontScale: snapshot.fontScale)
        let header = WorktreeSectionHeaderView(
            count: snapshot.worktrees.count,
            isCollapsed: snapshot.isCollapsed,
            metrics: metrics
        )
        header.onToggle = { [weak self] in self?.onToggleCollapsed?() }
        addArrangedRow(header)

        if !snapshot.isCollapsed {
            for worktree in snapshot.worktrees {
                let row = WorktreeRowView(
                    worktree: worktree,
                    isCurrent: Self.normalizedPath(worktree.path) == snapshot.currentPath,
                    sessionCount: snapshot.sessionCounts[worktree.path, default: 0],
                    metrics: metrics
                )
                row.onOpen = { [weak self] worktree in
                    self?.onOpenWorktree?(worktree)
                }
                addArrangedRow(row)
            }
        }

        requiredHeight = orderedRows.reduce(0) { $0 + $1.intrinsicContentSize.height }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func addArrangedRow(_ row: NSView) {
        addSubview(row)
        orderedRows.append(row)
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    fileprivate static func title(for worktree: GitStatusModel.Worktree) -> String {
        if let branch = worktree.branch { return branch }
        if worktree.isBare { return String(localized: "Bare repository") }
        if !worktree.shortHeadOID.isEmpty {
            return String(localized: "Detached at \(worktree.shortHeadOID)")
        }
        return String(localized: "Detached HEAD")
    }
}

@MainActor
private struct WorktreeMetrics {
    let scale: CGFloat
    let headerHeight: CGFloat
    let rowHeight: CGFloat
    let titleFont: NSFont
    let pathFont: NSFont
    let accessoryFont: NSFont
    let headerFont: NSFont

    init(fontScale: CGFloat) {
        scale = fontScale
        headerHeight = max(27, (27 * fontScale).rounded(.up))
        rowHeight = max(38, (40 * fontScale).rounded(.up))
        titleFont = .systemFont(ofSize: 11 * fontScale, weight: .regular)
        pathFont = .systemFont(ofSize: 9.5 * fontScale, weight: .regular)
        accessoryFont = .systemFont(ofSize: 8.5 * fontScale, weight: .medium)
        headerFont = .systemFont(ofSize: 9.5 * fontScale, weight: .medium)
    }
}

@MainActor
private final class WorktreeSectionHeaderView: NSView {
    var onToggle: (() -> Void)?

    private let count: Int
    private let isCollapsed: Bool
    private let metrics: WorktreeMetrics
    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: String(localized: "WORKTREES"))
    private let countLabel = NSTextField(labelWithString: "")

    init(count: Int, isCollapsed: Bool, metrics: WorktreeMetrics) {
        self.count = count
        self.isCollapsed = isCollapsed
        self.metrics = metrics
        super.init(frame: .zero)

        focusRingType = .default
        titleLabel.font = metrics.headerFont
        titleLabel.textColor = .secondaryLabelColor.withAlphaComponent(0.7)
        countLabel.stringValue = "\(count)"
        countLabel.font = metrics.accessoryFont
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .center
        chevron.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )
        chevron.symbolConfiguration = .init(pointSize: 7 * metrics.scale, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor.withAlphaComponent(0.7)

        addSubview(chevron)
        addSubview(titleLabel)
        addSubview(countLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Worktrees, \(count) items"))
        setAccessibilityValue(
            isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        )
        setAccessibilityHelp(String(localized: "Shows or hides Git worktrees"))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.headerHeight)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 5, dy: 2) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }

    override func layout() {
        super.layout()
        let contentY = max(0, metrics.headerHeight - 19)
        chevron.frame = NSRect(x: 8, y: contentY + 3, width: 8, height: 10)
        let countWidth = max(18, countLabel.intrinsicContentSize.width + 8)
        countLabel.frame = NSRect(
            x: bounds.width - countWidth - 8,
            y: contentY,
            width: countWidth,
            height: 16
        )
        titleLabel.frame = NSRect(
            x: 20,
            y: contentY,
            width: max(0, bounds.width - 20 - countWidth - 12),
            height: 16
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onToggle?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onToggle?()
        } else if event.keyCode == 123, !isCollapsed {
            onToggle?()
        } else if event.keyCode == 124, isCollapsed {
            onToggle?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}

@MainActor
private final class WorktreeRowView: NSView {
    let worktree: GitStatusModel.Worktree
    var onOpen: ((GitStatusModel.Worktree) -> Void)?

    private let isCurrent: Bool
    private let sessionCount: Int
    private let metrics: WorktreeMetrics
    private let canOpen: Bool
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let accessoryLabel = NSTextField(labelWithString: "")
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    init(
        worktree: GitStatusModel.Worktree,
        isCurrent: Bool,
        sessionCount: Int,
        metrics: WorktreeMetrics
    ) {
        self.worktree = worktree
        self.isCurrent = isCurrent
        self.sessionCount = sessionCount
        self.metrics = metrics
        canOpen = !worktree.isBare && worktree.prunableReason == nil
        super.init(frame: .zero)

        focusRingType = .default
        let title = WorktreesSectionNSView.title(for: worktree)
        var titleParts = [title]
        if worktree.lockedReason != nil { titleParts.append(String(localized: "locked")) }
        if worktree.prunableReason != nil { titleParts.append(String(localized: "prunable")) }
        titleLabel.stringValue = titleParts.joined(separator: " · ")
        titleLabel.font = metrics.titleFont
        titleLabel.textColor = canOpen ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        pathLabel.stringValue = (worktree.path as NSString).abbreviatingWithTildeInPath
        pathLabel.font = metrics.pathFont
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        var accessories: [String] = []
        if isCurrent { accessories.append("✓") }
        if sessionCount > 0 {
            accessories.append(String(localized: "\(sessionCount) open"))
        }
        accessoryLabel.stringValue = accessories.joined(separator: "  ")
        accessoryLabel.font = metrics.accessoryFont
        accessoryLabel.textColor = isCurrent ? Theme.accent : .tertiaryLabelColor
        accessoryLabel.alignment = .right

        icon.image = NSImage(
            systemSymbolName: worktree.isBare ? "externaldrive" : "arrow.triangle.branch",
            accessibilityDescription: nil
        )
        icon.symbolConfiguration = .init(pointSize: 9.5 * metrics.scale, weight: .medium)
        icon.contentTintColor = isCurrent ? Theme.accent : .secondaryLabelColor

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(pathLabel)
        addSubview(accessoryLabel)

        let stateDescription = [
            isCurrent ? String(localized: "current worktree") : nil,
            sessionCount > 0 ? String(localized: "\(sessionCount) open sessions") : nil,
            worktree.lockedReason.map { reason in
                reason.isEmpty ? String(localized: "locked") : String(localized: "locked, \(reason)")
            },
            worktree.prunableReason.map { reason in
                reason.isEmpty ? String(localized: "prunable") : String(localized: "prunable, \(reason)")
            },
        ].compactMap { $0 }.joined(separator: ", ")
        let accessibilityLabel = [title, worktree.path, stateDescription]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp(
            canOpen
                ? String(localized: "Opens or reveals this worktree as a Kero project")
                : String(localized: "This worktree cannot be opened")
        )
        setAccessibilityEnabled(canOpen)
        toolTip = accessibilityLabel
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { canOpen }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.rowHeight)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 3, dy: 1) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background: NSColor?
        if isCurrent {
            background = Theme.accent.withAlphaComponent(0.10)
        } else if isHovered {
            background = NSColor.labelColor.withAlphaComponent(0.055)
        } else {
            background = nil
        }
        if let background {
            background.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 5, yRadius: 5).fill()
    }

    override func layout() {
        super.layout()
        let iconSize = max(12, 12 * metrics.scale)
        icon.frame = NSRect(x: 8, y: 8, width: iconSize, height: iconSize)
        let contentX = 27 * metrics.scale
        let accessoryWidth = min(
            62 * metrics.scale,
            max(0, accessoryLabel.intrinsicContentSize.width)
        )
        accessoryLabel.frame = NSRect(
            x: max(contentX, bounds.width - accessoryWidth - 8),
            y: 4,
            width: accessoryWidth,
            height: 15 * metrics.scale
        )
        titleLabel.frame = NSRect(
            x: contentX,
            y: 3,
            width: max(0, bounds.width - contentX - accessoryWidth - 12),
            height: 16 * metrics.scale
        )
        pathLabel.frame = NSRect(
            x: contentX,
            y: 20 * metrics.scale,
            width: max(0, bounds.width - contentX - 8),
            height: 14 * metrics.scale
        )
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
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard canOpen else { return }
        window?.makeFirstResponder(self)
        onOpen?(worktree)
    }

    override func keyDown(with event: NSEvent) {
        if canOpen && (event.keyCode == 36 || event.keyCode == 49) {
            onOpen?(worktree)
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard canOpen else { return false }
        onOpen?(worktree)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let open = menu.addItem(
            withTitle: String(localized: "Open Worktree"),
            action: #selector(openFromMenu),
            keyEquivalent: ""
        )
        open.target = self
        open.isEnabled = canOpen
        menu.addItem(.separator())
        let copy = menu.addItem(
            withTitle: String(localized: "Copy Worktree Path"),
            action: #selector(copyPath),
            keyEquivalent: ""
        )
        copy.target = self
        let reveal = menu.addItem(
            withTitle: String(localized: "Reveal Worktree in Finder"),
            action: #selector(revealInFinder),
            keyEquivalent: ""
        )
        reveal.target = self
        reveal.isEnabled = FileManager.default.fileExists(atPath: worktree.path)
        return menu
    }

    @objc private func openFromMenu() { onOpen?(worktree) }
    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worktree.path, forType: .string)
    }
    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
    }
}
