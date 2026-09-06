//
//  GlobalShortcutSettingsView.swift
//  kero
//

import AppKit
import Carbon
import SwiftUI

@MainActor
final class GlobalShortcutSettingsView: NSView {
    private let titleLabel = NSTextField(labelWithString: String(localized: "Global shortcut"))
    private let detailLabel = NSTextField(
        wrappingLabelWithString: String(
            localized: "Shows or hides Kero from anywhere on your Mac"
        )
    )
    private let recorder = ShortcutRecorderButton(frame: .zero)
    private let clearButton = NSButton(
        title: String(localized: "Clear"),
        target: nil,
        action: nil
    )
    private let textStack = NSStackView()
    private let controlStack = NSStackView()

    var changeHandler: ((GlobalShortcut?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        recorder.controlSize = .small
        recorder.bezelStyle = .rounded
        recorder.setAccessibilityLabel(String(localized: "Global shortcut"))
        recorder.setAccessibilityHelp(
            String(localized: "Press to record a keyboard shortcut")
        )
        recorder.changeHandler = { [weak self] shortcut in
            self?.changeHandler?(shortcut)
            self?.apply(shortcut: shortcut)
        }

        clearButton.controlSize = .small
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)

        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 6
        controlStack.addArrangedSubview(recorder)
        controlStack.addArrangedSubview(clearButton)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        addSubview(controlStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.topAnchor.constraint(equalTo: topAnchor),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -16),
            controlStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlStack.topAnchor.constraint(equalTo: topAnchor),
            recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(shortcut: GlobalShortcut?) {
        recorder.apply(shortcut: shortcut)
        clearButton.isEnabled = shortcut != nil
    }

    @objc private func clearShortcut() {
        changeHandler?(nil)
        apply(shortcut: nil)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(max(max(textStack.fittingSize.height, controlStack.fittingSize.height), 44))
        )
    }
}

@MainActor
private final class ShortcutRecorderButton: NSButton {
    var changeHandler: ((GlobalShortcut?) -> Void)?

    private var shortcut: GlobalShortcut?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(beginRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(shortcut: GlobalShortcut?) {
        self.shortcut = shortcut
        guard !isRecording else { return }
        title = shortcut?.displayName ?? String(localized: "Not Set")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { finishRecording() }
        return super.resignFirstResponder()
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = String(localized: "Type Shortcut")
        GlobalHotKeyController.shared.setRecording(true)
        if window?.makeFirstResponder(self) != true {
            finishRecording()
        }
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            finishRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete), flags.isEmpty {
            shortcut = nil
            changeHandler?(nil)
            finishRecording()
            return
        }
        guard let shortcut = GlobalShortcut(event: event) else {
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        changeHandler?(shortcut)
        finishRecording()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        title = shortcut?.displayName ?? String(localized: "Not Set")
        GlobalHotKeyController.shared.setRecording(false)
    }
}

struct GlobalShortcutSettingsRow: NSViewRepresentable {
    let shortcut: GlobalShortcut?
    let onChange: (GlobalShortcut?) -> Void

    func makeNSView(context: Context) -> GlobalShortcutSettingsView {
        let view = GlobalShortcutSettingsView(frame: .zero)
        view.changeHandler = onChange
        view.apply(shortcut: shortcut)
        return view
    }

    func updateNSView(_ view: GlobalShortcutSettingsView, context: Context) {
        view.changeHandler = onChange
        view.apply(shortcut: shortcut)
    }
}
