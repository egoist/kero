//
//  AgentPalette.swift
//  kero
//

import AppKit
import FuzzyMatch
import SwiftUI

private enum AgentPaletteLayout {
    static let panelWidth: CGFloat = 920
    static let topInset: CGFloat = 96
    /// The list needs only enough width for an alias over a path; every point
    /// beyond that is better spent on the capture, which is far wider.
    static let listWidth: CGFloat = 336
    static let cornerRadius: CGFloat = 14
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 30
    static let gutter: CGFloat = 14
    /// The body grows with the result count between these bounds, so a single
    /// match does not leave a wall of empty space and a long list still fits.
    static let minBodyHeight: CGFloat = 216
    static let maxBodyHeight: CGFloat = 348
}

/// ⌥⌘A overlay: every running agent across every project, filterable by typed
/// tokens, with the highlighted agent's terminal tail beside the list.
///
/// Row membership and order are settled on each keystroke and then held still.
/// Agents change phase on a sub-second cadence, so re-sorting on every refresh
/// would slide the row out from under Return; instead the periodic refresh
/// only restates badges and drops rows whose session has closed. A newly
/// started agent joins the list on the next keystroke.
@MainActor
final class AgentPaletteViewController: NSViewController {
    private let manager: TerminalManager

    private let panel = AgentPalettePanelView(frame: .zero)
    private let searchField = NSTextField()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private let preview = AgentPalettePreviewView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")
    private var bodyHeightConstraint: NSLayoutConstraint?

    /// Every agent session right now, rebuilt on demand.
    private var allEntries: [AgentPaletteEntry] = []
    /// The rows on screen. Order is recomputed only when the query changes.
    private var visibleEntries: [AgentPaletteEntry] = []
    private var selectedSessionID: UUID?
    /// The query the visible rows were built from, so the periodic refresh can
    /// restate the header without re-parsing the field.
    private var activeQuery = AgentPaletteQuery()
    private var refreshTimer: Timer?

    private static let fuzzyMatcher = FuzzyMatcher(config: .smithWaterman)

    init(manager: TerminalManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = AgentPaletteBackdropView { [weak self] in self?.dismiss() }
        buildPanel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyQuery()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        startRefreshTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopTimers()
        manager.restoreFocusAfterPalette()
    }

    private func stopTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        preview.clear()
    }

    // MARK: - Chrome

    private func buildPanel() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let magnifier = NSImageView()
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        magnifier.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil
        )
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 14, weight: .medium
        )
        magnifier.contentTintColor = .tertiaryLabelColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.delegate = self
        searchField.placeholderString = String(
            localized: "Search agents…",
            comment: "Placeholder in the agent palette search field."
        )
        searchField.setAccessibilityLabel(
            String(localized: "Search agents", comment: "Accessibility label.")
        )

        // Doubles as the result count, so the header never holds empty space.
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .tertiaryLabelColor
        summaryLabel.alignment = .right
        summaryLabel.lineBreakMode = .byTruncatingHead
        summaryLabel.setContentCompressionResistancePriority(
            .defaultHigh, for: .horizontal
        )

        let headerRule = NSBox()
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        headerRule.boxType = .separator

        let footerRule = NSBox()
        footerRule.translatesAutoresizingMaskIntoConstraints = false
        footerRule.boxType = .separator

        let verticalRule = NSBox()
        verticalRule.translatesAutoresizingMaskIntoConstraints = false
        verticalRule.boxType = .separator

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let keyHints = NSTextField(labelWithString: String(
            localized: "⌃N/⌃P move · ↩ jump · ⎋ close",
            comment: "Key hints along the bottom of the agent palette."
        ))
        keyHints.translatesAutoresizingMaskIntoConstraints = false
        keyHints.font = .systemFont(ofSize: 10)
        keyHints.textColor = .tertiaryLabelColor

        // Filter syntax lives here rather than in the placeholder, so it stays
        // discoverable without shouting over the field the user types into.
        let filterHints = NSTextField(labelWithString: String(
            localized: "status:  agent:  project:",
            comment: "Available agent palette filter prefixes."
        ))
        filterHints.translatesAutoresizingMaskIntoConstraints = false
        filterHints.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        filterHints.textColor = .quaternaryLabelColor

        buildList()

        for subview in [
            magnifier, searchField, summaryLabel, headerRule, tableScrollView,
            emptyLabel, verticalRule, preview, footerRule, keyHints,
            filterHints,
        ] as [NSView] {
            panel.addSubview(subview)
        }

        let bodyHeight = tableScrollView.heightAnchor.constraint(
            equalToConstant: AgentPaletteLayout.minBodyHeight
        )
        bodyHeightConstraint = bodyHeight

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.topAnchor.constraint(
                equalTo: view.topAnchor, constant: AgentPaletteLayout.topInset
            ),
            panel.widthAnchor.constraint(
                equalToConstant: AgentPaletteLayout.panelWidth
            ),

            // An NSTextField draws its text at the top of its frame, so the
            // field is centred on the header rather than stretched to fill it.
            magnifier.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: AgentPaletteLayout.gutter
            ),
            magnifier.centerYAnchor.constraint(
                equalTo: searchField.centerYAnchor
            ),
            magnifier.widthAnchor.constraint(equalToConstant: 17),

            searchField.leadingAnchor.constraint(
                equalTo: magnifier.trailingAnchor, constant: 9
            ),
            searchField.topAnchor.constraint(
                equalTo: panel.topAnchor,
                constant: (AgentPaletteLayout.headerHeight - 19) / 2
            ),

            summaryLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: searchField.trailingAnchor, constant: 12
            ),
            summaryLabel.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -AgentPaletteLayout.gutter
            ),
            summaryLabel.firstBaselineAnchor.constraint(
                equalTo: searchField.firstBaselineAnchor
            ),

            headerRule.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            headerRule.topAnchor.constraint(
                equalTo: panel.topAnchor,
                constant: AgentPaletteLayout.headerHeight
            ),

            tableScrollView.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: 8
            ),
            tableScrollView.topAnchor.constraint(
                equalTo: headerRule.bottomAnchor, constant: 8
            ),
            tableScrollView.widthAnchor.constraint(
                equalToConstant: AgentPaletteLayout.listWidth
            ),
            bodyHeight,

            emptyLabel.centerXAnchor.constraint(
                equalTo: tableScrollView.centerXAnchor
            ),
            emptyLabel.centerYAnchor.constraint(
                equalTo: tableScrollView.centerYAnchor
            ),
            emptyLabel.widthAnchor.constraint(
                equalTo: tableScrollView.widthAnchor
            ),

            verticalRule.leadingAnchor.constraint(
                equalTo: tableScrollView.trailingAnchor, constant: 8
            ),
            verticalRule.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            verticalRule.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            verticalRule.widthAnchor.constraint(equalToConstant: 1),

            preview.leadingAnchor.constraint(
                equalTo: verticalRule.trailingAnchor, constant: 8
            ),
            preview.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -8
            ),
            preview.topAnchor.constraint(
                equalTo: tableScrollView.topAnchor
            ),
            preview.bottomAnchor.constraint(
                equalTo: tableScrollView.bottomAnchor
            ),

            footerRule.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            footerRule.topAnchor.constraint(
                equalTo: tableScrollView.bottomAnchor, constant: 8
            ),

            keyHints.leadingAnchor.constraint(
                equalTo: panel.leadingAnchor, constant: AgentPaletteLayout.gutter
            ),
            keyHints.centerYAnchor.constraint(
                equalTo: footerRule.bottomAnchor,
                constant: AgentPaletteLayout.footerHeight / 2
            ),

            filterHints.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -AgentPaletteLayout.gutter
            ),
            filterHints.centerYAnchor.constraint(equalTo: keyHints.centerYAnchor),

            panel.bottomAnchor.constraint(
                equalTo: footerRule.bottomAnchor,
                constant: AgentPaletteLayout.footerHeight
            ),
        ])
    }

    /// Grow the list to its contents between the layout's bounds. Sizing on
    /// the result count keeps one match from sitting in a wall of empty space.
    private func updateBodyHeight() {
        let contentHeight = CGFloat(max(visibleEntries.count, 1))
            * (AgentPaletteLayout.rowHeight + 1) + 8
        bodyHeightConstraint?.constant = min(
            max(contentHeight, AgentPaletteLayout.minBodyHeight),
            AgentPaletteLayout.maxBodyHeight
        )
    }

    private func buildList() {
        tableView.headerView = nil
        tableView.rowHeight = AgentPaletteLayout.rowHeight
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        // The search field keeps focus for the whole gesture; the list is
        // driven programmatically and must never take the responder.
        tableView.refusesFirstResponder = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("agent")
        )
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.drawsBackground = false
        tableScrollView.autohidesScrollers = true
    }

    // MARK: - Data

    /// Walks projects in window order so an unfiltered list matches the project
    /// sidebar and tab strip wherever attention rank ties.
    private func rebuildSnapshot() {
        var entries: [AgentPaletteEntry] = []
        for project in manager.projects {
            let projectName = project.name
            for tab in project.tabs {
                let tabTitle = tab.displayTitle ?? String(
                    localized: "Untitled", comment: "Fallback tab title."
                )
                for session in tab.sessions {
                    guard let status = session.agentStatus else { continue }
                    let directory = session.currentDirectoryPath.abbreviatingHomeDirectory
                    entries.append(
                        AgentPaletteEntry(
                            sessionID: session.id,
                            alias: status.alias,
                            kind: status.kind,
                            projectName: projectName,
                            tabTitle: tabTitle,
                            directory: directory,
                            searchText: [
                                status.alias, status.kind.displayName,
                                projectName, tabTitle, directory,
                            ].joined(separator: " "),
                            phase: status.phase,
                            unseen: status.unseen,
                            updatedAt: status.updatedAt
                        )
                    )
                }
            }
        }
        allEntries = entries
    }

    /// Recompute membership and order from the current query. The only path
    /// allowed to move a row.
    private func applyQuery() {
        rebuildSnapshot()
        let query = AgentPaletteQuery.parse(searchField.stringValue)
        activeQuery = query

        var candidates = allEntries.filter { query.admits($0) }
        if query.freeText.isEmpty {
            candidates.sort(by: Self.byAttention)
        } else {
            let fuzzyQuery = Self.fuzzyMatcher.prepare(query.freeText)
            var buffer = Self.fuzzyMatcher.makeBuffer()
            var scored: [(entry: AgentPaletteEntry, score: Double)] = []
            for entry in candidates {
                guard let score = Self.fuzzyScore(
                    entry.searchText, fuzzyQuery, buffer: &buffer
                ) else { continue }
                scored.append((entry, score))
            }
            scored.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return Self.byAttention($0.entry, $1.entry)
            }
            candidates = scored.map(\.entry)
        }

        visibleEntries = candidates
        tableView.reloadData()
        updateBodyHeight()
        updateSummary(query)
        updateEmptyState()
        select(row: 0, scroll: true)
    }

    /// Right side of the header: how many agents matched, and what the typed
    /// tokens were understood to mean.
    private func updateSummary(_ query: AgentPaletteQuery) {
        let count = visibleEntries.count
        let total = allEntries.count
        var parts: [String] = []
        if count == total {
            parts.append(count == 1
                ? String(localized: "1 agent", comment: "Agent palette count.")
                : String(localized: "\(count) agents", comment: "Agent palette count."))
        } else {
            parts.append(String(
                localized: "\(count) of \(total)",
                comment: "Agent palette count when filters are narrowing the list."
            ))
        }
        if let summary = query.summary { parts.append(summary) }
        summaryLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    /// Periodic refresh: status only. Rows never move and new agents never
    /// appear here — both would disturb a selection the user is aiming at.
    /// Closed sessions do drop out, since jumping to one is a dead end.
    private func refreshStatuses() {
        // Only the three status fields can have changed, so look each visible
        // row up by identity rather than rebuilding the whole snapshot. That
        // keeps a sub-second timer off the walk over every project, tab, and
        // session, and away from rebuilding search strings nothing reads here.
        var refreshed: [AgentPaletteEntry] = []
        refreshed.reserveCapacity(visibleEntries.count)
        for var entry in visibleEntries {
            guard let status = manager.session(withID: entry.sessionID)?.agentStatus
            else { continue }
            entry.phase = status.phase
            entry.unseen = status.unseen
            entry.updatedAt = status.updatedAt
            refreshed.append(entry)
        }

        let membershipChanged = refreshed.count != visibleEntries.count
        visibleEntries = refreshed

        tableView.reloadData()
        if membershipChanged {
            // The count in the header is drawn from both lists, so the full
            // snapshot is only worth rebuilding when one of them shrank.
            rebuildSnapshot()
            updateBodyHeight()
            updateSummary(activeQuery)
            updateEmptyState()
        }
        restoreSelection()
        refreshPreview(debounced: false)
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !visibleEntries.isEmpty
        emptyLabel.stringValue = allEntries.isEmpty
            ? String(
                localized: "No agents running",
                comment: "Agent palette empty state when no agent is active anywhere."
            )
            : String(
                localized: "No agents match",
                comment: "Agent palette empty state when the filters exclude every agent."
            )
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        // Matches the automation monitor's own cadence, so a badge here never
        // lags the one in the tab strip by more than a tick.
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.refreshStatuses()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private static func byAttention(
        _ lhs: AgentPaletteEntry, _ rhs: AgentPaletteEntry
    ) -> Bool {
        if lhs.attentionRank != rhs.attentionRank {
            return lhs.attentionRank < rhs.attentionRank
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    // MARK: - Selection

    private var selectedRow: Int? {
        guard let selectedSessionID else { return nil }
        return visibleEntries.firstIndex { $0.sessionID == selectedSessionID }
    }

    private func select(row: Int, scroll: Bool) {
        guard visibleEntries.indices.contains(row) else {
            selectedSessionID = nil
            preview.clear()
            return
        }
        selectedSessionID = visibleEntries[row].sessionID
        tableView.selectRowIndexes(
            IndexSet(integer: row), byExtendingSelection: false
        )
        if scroll { tableView.scrollRowToVisible(row) }
        refreshPreview(debounced: true)
    }

    /// After a membership change, keep the same agent selected where possible
    /// and otherwise fall back to the top of the list.
    private func restoreSelection() {
        if let row = selectedRow {
            tableView.selectRowIndexes(
                IndexSet(integer: row), byExtendingSelection: false
            )
            return
        }
        select(row: 0, scroll: false)
    }

    private func move(_ delta: Int) {
        guard !visibleEntries.isEmpty else { return }
        let current = selectedRow ?? 0
        let next = (current + delta + visibleEntries.count) % visibleEntries.count
        select(row: next, scroll: true)
    }

    // MARK: - Preview

    /// Hands the highlighted agent to the preview, which owns its own scroll
    /// position, debounce, and change detection. `debounced` marks a move
    /// through the list, where key repeat would otherwise export a screen per
    /// row; the periodic refresh renders immediately.
    private func refreshPreview(debounced: Bool) {
        guard let row = selectedRow else {
            preview.clear()
            return
        }
        let sessionID = visibleEntries[row].sessionID
        preview.show(
            manager.session(withID: sessionID),
            id: sessionID,
            debounced: debounced
        )
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard visibleEntries.indices.contains(row) else { return }
        select(row: row, scroll: false)
        activateSelection()
    }

    private func activateSelection() {
        guard let row = selectedRow,
              let session = manager.session(withID: visibleEntries[row].sessionID)
        else { return }
        dismiss()
        manager.revealSession(session)
        // Jumping to an agent is the explicit focus action that acknowledges a
        // finished run, exactly as the ⇧⌘A cycle treats it.
        session.markAutomationAgentSeen()
    }

    private func dismiss() {
        manager.dismissAgentPalette()
    }

    private func handleEscape() {
        if searchField.stringValue.isEmpty {
            dismiss()
        } else {
            searchField.stringValue = ""
            applyQuery()
        }
    }

    /// Score via the library's prepared-query, reusable-buffer UTF-8 API, the
    /// same path the ⌘P palette uses to stay allocation-free per candidate.
    @inline(__always)
    private static func fuzzyScore(
        _ candidate: String,
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        var candidate = candidate
        return candidate.withUTF8 { bytes in
            fuzzyMatcher.score(utf8: bytes, against: query, buffer: &buffer)?.score
        }
    }
}

extension AgentPaletteViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        applyQuery()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        // AppKit's default bindings already map ⌃N/⌃P onto these two, so
        // handling them covers both the arrows and the emacs pair.
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            move(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape()
            return true
        default:
            return false
        }
    }
}

extension AgentPaletteViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    func tableView(
        _ tableView: NSTableView, rowViewForRow row: Int
    ) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("agentRow")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self)
            as? AgentPaletteRowBackgroundView
            ?? AgentPaletteRowBackgroundView(frame: .zero)
        rowView.identifier = identifier
        // The palette owns its highlight; AppKit's emphasized blue would fight
        // the badge colors that carry the actual status.
        rowView.isEmphasized = false
        return rowView
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard visibleEntries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("agentCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? AgentPaletteCellView ?? AgentPaletteCellView(frame: .zero)
        cell.identifier = identifier
        cell.apply(visibleEntries[row])
        return cell
    }
}

/// Panel chrome. Layer colors are resolved rather than dynamic, so they are
/// reapplied whenever the effective appearance changes.
private final class AgentPalettePanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = AgentPaletteLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        self.shadow = shadow
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Dim backdrop that closes the palette when clicked outside the panel.
private final class AgentPaletteBackdropView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    /// The terminal surface underneath sets an I-beam cursor rect that would
    /// otherwise show through the whole backdrop.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Mount point only. All palette rendering, layout, and interaction lives in
/// the AppKit controller above.
struct AgentPaletteMount: NSViewControllerRepresentable {
    let manager: TerminalManager

    func makeNSViewController(context: Context) -> AgentPaletteViewController {
        AgentPaletteViewController(manager: manager)
    }

    func updateNSViewController(
        _ controller: AgentPaletteViewController, context: Context
    ) {}
}
