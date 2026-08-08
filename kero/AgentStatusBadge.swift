//
//  AgentStatusBadge.swift
//  kero
//

import AppKit
import SwiftUI

/// Native, allocation-light agent status chrome reused by panes, tabs, and
/// project rows. Shape, color, tooltip, and accessibility label all encode the
/// state, so status never depends on color alone.
final class AgentStatusBadgeView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private var phase: KeroAgentPhase?
    private var count = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 10.5, weight: .semibold
        )
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(imageView)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13),
            countLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 2),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 15),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(phase: KeroAgentPhase, count: Int) {
        guard self.phase != phase || self.count != count else { return }
        self.phase = phase
        self.count = count
        imageView.image = NSImage(systemSymbolName: symbolName(for: phase), accessibilityDescription: nil)
        imageView.contentTintColor = color(for: phase)
        countLabel.stringValue = count > 1 ? "\(count)" : ""
        countLabel.isHidden = count <= 1
        let description = statusDescription(phase: phase, count: count)
        toolTip = description
        setAccessibilityLabel(description)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: count > 1 ? 26 : 13, height: 15)
    }

    private func symbolName(for phase: KeroAgentPhase) -> String {
        switch phase {
        case .created: return "plus.circle"
        case .working: return "bolt.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .idle: return "pause.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(for phase: KeroAgentPhase) -> NSColor {
        switch phase {
        case .created: return .secondaryLabelColor
        case .working: return .systemBlue
        case .blocked: return .systemOrange
        case .done: return .systemGreen
        case .idle: return .secondaryLabelColor
        case .unknown: return .tertiaryLabelColor
        }
    }

    private func statusDescription(phase: KeroAgentPhase, count: Int) -> String {
        let state: String = switch phase {
        case .created: String(localized: "created")
        case .working: String(localized: "working")
        case .blocked: String(localized: "blocked")
        case .done: String(localized: "done")
        case .idle: String(localized: "idle")
        case .unknown: String(localized: "unknown")
        }
        return count == 1
            ? String(localized: "Agent \(state)")
            : String(localized: "\(count) agents \(state)")
    }
}

/// Existing screen composition is still SwiftUI; this representable is only
/// the mount point for the AppKit view above. No status rendering or layout is
/// implemented in SwiftUI.
struct AgentStatusBadgeRepresentable: NSViewRepresentable {
    let rollup: KeroAgentRollup

    func makeNSView(context: Context) -> AgentStatusBadgeView {
        let view = AgentStatusBadgeView(frame: .zero)
        view.apply(phase: rollup.phase, count: rollup.count)
        return view
    }

    func updateNSView(_ view: AgentStatusBadgeView, context: Context) {
        view.apply(phase: rollup.phase, count: rollup.count)
    }
}
