//
//  AgentPaletteRow.swift
//  kero
//

import AppKit

/// How a phase reads in a list, where the badge's shape-and-color encoding is
/// glanceable but not precise — a resting ring and a starting ring are a pixel
/// apart. A picker whose whole job is choosing by state needs the word too.
extension KeroAgentPhase {
    /// Matches the vocabulary the status badge's own tooltips use.
    var paletteLabel: String {
        switch self {
        case .created: return String(localized: "starting", comment: "Agent state.")
        case .working: return String(localized: "working", comment: "Agent state.")
        case .blocked: return String(localized: "needs you", comment: "Agent state.")
        case .done: return String(localized: "finished", comment: "Agent state.")
        case .idle: return String(localized: "idle", comment: "Agent state.")
        case .unknown: return String(localized: "unknown", comment: "Agent state.")
        }
    }

    /// Only the states that also post a notification carry color; the resting
    /// ones stay grey so a wall of running agents never shouts. This mirrors
    /// the tiering `AgentStatusBadgeView` documents and draws.
    var paletteTint: NSColor {
        switch self {
        case .blocked: return .systemOrange
        case .done: return .systemGreen
        case .working: return .systemBlue
        case .created, .idle, .unknown: return .tertiaryLabelColor
        }
    }
}

/// Rounded selection fill matching the ⌘P palette's row highlight; AppKit's
/// own regular and source-list styles both draw a full-bleed bar.
final class AgentPaletteRowBackgroundView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7
        )
        NSColor.labelColor.withAlphaComponent(0.085).setFill()
        path.fill()
    }
}

/// One agent row, in two lines: the agent's identity over the directory it is
/// working in, with its state and age held in a fixed right-hand column.
///
/// The directory is the line that actually distinguishes two runs of the same
/// CLI, so it gets the width and truncates from the head — the tail of a path
/// carries the repository name, the head carries `/Users/someone`.
final class AgentPaletteCellView: NSTableCellView {
    private let badge = AgentStatusBadgeView(frame: .zero)
    private let aliasLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        aliasLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        aliasLabel.textColor = .labelColor
        aliasLabel.lineBreakMode = .byTruncatingTail

        directoryLabel.font = .systemFont(ofSize: 10.5)
        directoryLabel.textColor = .tertiaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingHead

        phaseLabel.font = .systemFont(ofSize: 10, weight: .medium)
        phaseLabel.alignment = .right

        ageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ageLabel.textColor = .quaternaryLabelColor
        ageLabel.alignment = .right

        for label in [aliasLabel, directoryLabel, phaseLabel, ageLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        addSubview(badge)

        directoryLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal
        )
        directoryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for label in [aliasLabel, phaseLabel, ageLabel] {
            label.setContentCompressionResistancePriority(
                .defaultHigh, for: .horizontal
            )
        }

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),

            aliasLabel.leadingAnchor.constraint(
                equalTo: badge.trailingAnchor, constant: 10
            ),
            aliasLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            aliasLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: phaseLabel.leadingAnchor, constant: -8
            ),

            directoryLabel.leadingAnchor.constraint(
                equalTo: aliasLabel.leadingAnchor
            ),
            directoryLabel.topAnchor.constraint(
                equalTo: aliasLabel.bottomAnchor, constant: 1
            ),
            directoryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: ageLabel.leadingAnchor, constant: -8
            ),

            phaseLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12
            ),
            phaseLabel.firstBaselineAnchor.constraint(
                equalTo: aliasLabel.firstBaselineAnchor
            ),

            ageLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -12
            ),
            ageLabel.firstBaselineAnchor.constraint(
                equalTo: directoryLabel.firstBaselineAnchor
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ entry: AgentPaletteEntry) {
        badge.apply(phase: entry.phase, count: 1)
        aliasLabel.stringValue = entry.alias
        directoryLabel.stringValue = entry.directory.isEmpty
            ? entry.projectName
            : entry.directory
        directoryLabel.toolTip = entry.tabTitle
        phaseLabel.stringValue = entry.phase.paletteLabel
        phaseLabel.textColor = entry.phase.paletteTint
        ageLabel.stringValue = Self.age(since: entry.updatedAt)

        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(
            "\(entry.alias), \(entry.phase.paletteLabel), \(directoryLabel.stringValue)"
        )
    }

    /// Compact elapsed time — a status column, not prose, so it has to stay
    /// narrow and stable in width.
    private static func age(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

