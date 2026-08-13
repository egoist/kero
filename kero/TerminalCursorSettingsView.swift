//
//  TerminalCursorSettingsView.swift
//  kero
//

import AppKit
import SwiftUI

/// AppKit-owned cursor shape row for the legacy SwiftUI Settings mount point.
@MainActor
final class TerminalCursorShapeSettingsView: NSView {
    private let titleLabel = NSTextField(
        labelWithString: String(localized: "Cursor shape")
    )
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    var changeHandler: ((TerminalCursorShape) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(shapeChanged)
        popup.setAccessibilityLabel(String(localized: "Cursor shape"))
        for shape in TerminalCursorShape.allCases {
            let item = NSMenuItem(title: shape.title, action: nil, keyEquivalent: "")
            item.representedObject = shape.rawValue
            popup.menu?.addItem(item)
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(titleLabel)
        addSubview(popup)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: popup.leadingAnchor,
                constant: -16
            ),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(shape: TerminalCursorShape) {
        guard let index = popup.itemArray.firstIndex(where: {
            $0.representedObject as? String == shape.rawValue
        }) else { return }
        popup.selectItem(at: index)
    }

    @objc private func shapeChanged() {
        guard
            let rawValue = popup.selectedItem?.representedObject as? String,
            let shape = TerminalCursorShape(rawValue: rawValue)
        else { return }
        changeHandler?(shape)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(max(titleLabel.fittingSize.height, popup.fittingSize.height))
        )
    }
}

/// AppKit-owned cursor blinking row for the legacy SwiftUI Settings mount point.
@MainActor
final class TerminalCursorBlinkingSettingsView: NSView {
    private let titleLabel = NSTextField(
        labelWithString: String(localized: "Blink cursor")
    )
    private let toggle = NSSwitch(frame: .zero)

    var changeHandler: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(blinkingChanged)
        toggle.setAccessibilityLabel(String(localized: "Blink cursor"))

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(titleLabel)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: toggle.leadingAnchor,
                constant: -16
            ),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(isBlinking: Bool) {
        toggle.state = isBlinking ? .on : .off
    }

    @objc private func blinkingChanged() {
        changeHandler?(toggle.state == .on)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(max(titleLabel.fittingSize.height, toggle.fittingSize.height))
        )
    }
}

/// SwiftUI only mounts the native rows inside the pre-existing Settings form.
struct TerminalCursorShapeSettingsRow: NSViewRepresentable {
    let shape: TerminalCursorShape
    let onChange: (TerminalCursorShape) -> Void

    func makeNSView(context: Context) -> TerminalCursorShapeSettingsView {
        let view = TerminalCursorShapeSettingsView(frame: .zero)
        view.changeHandler = onChange
        view.apply(shape: shape)
        return view
    }

    func updateNSView(_ view: TerminalCursorShapeSettingsView, context: Context) {
        view.changeHandler = onChange
        view.apply(shape: shape)
    }
}

struct TerminalCursorBlinkingSettingsRow: NSViewRepresentable {
    let isBlinking: Bool
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TerminalCursorBlinkingSettingsView {
        let view = TerminalCursorBlinkingSettingsView(frame: .zero)
        view.changeHandler = onChange
        view.apply(isBlinking: isBlinking)
        return view
    }

    func updateNSView(_ view: TerminalCursorBlinkingSettingsView, context: Context) {
        view.changeHandler = onChange
        view.apply(isBlinking: isBlinking)
    }
}
