//
//  MarkdownModeChip.swift
//  kero
//

import AppKit
import Combine

/// Whether markdown tabs open rendered or as source. Sticky across tabs and
/// launches, like the diff viewer's review/edit choice: pick source once and
/// the next `.md` file opens there too.
@MainActor
final class MarkdownViewPreferences: ObservableObject {
    static let shared = MarkdownViewPreferences()

    private static let modeKey = "markdownView.mode"

    @Published var showsSource: Bool {
        didSet {
            UserDefaults.standard.set(showsSource ? "source" : "preview", forKey: Self.modeKey)
        }
    }

    private init() {
        showsSource = UserDefaults.standard.string(forKey: Self.modeKey) == "source"
    }
}

/// The floating pill in the top-right of a markdown pane that swaps between the
/// rendered document and its source.
///
/// It names the *action*, not the current state — "Edit" while reading, "Preview"
/// while editing — so one glance says what the click will do. It stays visible
/// in both modes: hiding it in source mode would leave the way back invisible.
@MainActor
final class MarkdownModeChipView: NSView {
    var onToggle: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var showsSource = false
    private var hovering = false

    /// Clears the vertical scroller (~15pt) plus a margin, so the chip and the
    /// scroll thumb never overlap when the pointer brings the scroller out.
    static let trailingInset: CGFloat = 22
    static let topInset: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        updateAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(showsSource: Bool) {
        guard self.showsSource != showsSource || label.stringValue.isEmpty else { return }
        self.showsSource = showsSource
        if showsSource {
            label.stringValue = String(
                localized: "Preview",
                comment: "Switches a markdown file from its source back to the rendered document."
            )
            icon.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        } else {
            label.stringValue = String(
                localized: "Edit",
                comment: "Switches a rendered markdown file to its editable source."
            )
            icon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        }
        setAccessibilityLabel(label.stringValue)
        updateAlpha()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateAlpha()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateAlpha()
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    /// Full strength over the rendered document, where the chip is the only way
    /// back to the source; dimmed over the editor, which is a work surface the
    /// chip should stay out of until it is wanted.
    private func updateAlpha() {
        alphaValue = (showsSource && !hovering) ? 0.4 : 1
    }

    private func updateAppearanceColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = Theme.terminal(dark: isDark)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = theme.surfaceNSColor(elevation: 0.08).cgColor
            layer?.borderColor = theme.surfaceNSColor(elevation: 0.18).cgColor
        }
        let foreground = theme.surfaceNSColor(elevation: 0.6)
        label.textColor = foreground
        icon.contentTintColor = foreground
    }
}
