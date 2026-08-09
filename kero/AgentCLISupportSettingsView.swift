//
//  AgentCLISupportSettingsView.swift
//  kero
//

import AppKit
import SwiftUI

/// AppKit-owned Settings row for Kero's agent coordination integrations.
/// The existing Settings screen remains the legacy SwiftUI mount point only.
@MainActor
final class AgentCLISupportSettingsView: NSView {
    private let titleLabel = NSTextField(labelWithString: String(localized: "AI"))
    private let detailLabel = NSTextField(
        wrappingLabelWithString: String(
            localized: "Lets agents delegate work and coordinate across Kero panes"
        )
    )
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSSwitch(frame: .zero)
    private let textStack = NSStackView()

    private var appliedEnabled = false
    var changeHandler: ((Bool) throws -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.detachesHiddenViews = true
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)
        textStack.addArrangedSubview(errorLabel)
        textStack.setCustomSpacing(5, after: detailLabel)

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.setAccessibilityLabel(String(localized: "AI"))
        toggle.setAccessibilityHelp(detailLabel.stringValue)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.topAnchor.constraint(equalTo: topAnchor),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -16),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.topAnchor.constraint(equalTo: topAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(isEnabled: Bool) {
        appliedEnabled = isEnabled
        toggle.state = isEnabled ? .on : .off
    }

    @objc private func toggleChanged() {
        let requested = toggle.state == .on
        do {
            try changeHandler?(requested)
            appliedEnabled = requested
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        } catch {
            toggle.state = appliedEnabled ? .on : .off
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(max(max(textStack.fittingSize.height, toggle.fittingSize.height), 44))
        )
    }
}

/// SwiftUI only mounts the native row inside the pre-existing Settings form.
struct AgentCLISupportSettingsRow: NSViewRepresentable {
    let isEnabled: Bool
    let onChange: (Bool) throws -> Void

    func makeNSView(context: Context) -> AgentCLISupportSettingsView {
        let view = AgentCLISupportSettingsView(frame: .zero)
        view.changeHandler = onChange
        view.apply(isEnabled: isEnabled)
        return view
    }

    func updateNSView(_ view: AgentCLISupportSettingsView, context: Context) {
        view.changeHandler = onChange
        view.apply(isEnabled: isEnabled)
    }
}
