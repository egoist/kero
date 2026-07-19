//
//  OverlayScrollbarView.swift
//  kero
//

import AppKit

/// A native-style overlay scrollbar for the terminal: a slim rounded thumb
/// floating over the content with no track. It appears on scroll activity,
/// fades away when idle, widens while hovered or dragged, and supports
/// dragging and jump-to-spot clicks. Mouse events pass through to the
/// terminal whenever the thumb is faded out.
final class OverlayScrollbarView: NSView {
    /// Width of the strip along the terminal's trailing edge that the
    /// view occupies (and within which the thumb is hit-testable).
    static let stripWidth: CGFloat = 14

    /// Called with the target scroll position (0…1) while the user drags.
    var onScroll: ((Double) -> Void)?

    private var position: Double = 0 // 0 = top of scrollback, 1 = bottom
    private var proportion: Double = 1 // viewport height / content height
    private var active = false // whether there is anything to scroll

    private var hovering = false
    private var dragging = false
    private var dragOffset: CGFloat = 0 // grab point within the thumb
    private var shown = false
    private var fadeTimer: Timer?

    private let edgeInset: CGFloat = 3
    private let minThumbLength: CGFloat = 24

    override var isFlipped: Bool { true }

    // MARK: - State pushed from the terminal

    func update(position: Double, proportion: Double, active: Bool) {
        let oldPosition = self.position
        let oldProportion = self.proportion
        // While dragging, this view is the source of truth for position;
        // echoes from the terminal (snapped to whole rows) would jitter.
        if !dragging {
            self.position = min(max(position, 0), 1)
        }
        self.proportion = min(max(proportion, 0.01), 1)
        self.active = active

        guard active else {
            fadeTimer?.invalidate()
            shown = false
            hovering = false
            alphaValue = 0
            return
        }
        if self.position != oldPosition || self.proportion != oldProportion {
            needsDisplay = true
            reveal()
        }
    }

    // MARK: - Thumb geometry (flipped: y grows downward)

    private var trackLength: CGFloat { bounds.height - 2 * edgeInset }

    private var thumbLength: CGFloat {
        min(max(minThumbLength, trackLength * proportion), trackLength)
    }

    private var thumbRect: NSRect {
        let width: CGFloat = (hovering || dragging) ? 8 : 5
        let y = edgeInset + (trackLength - thumbLength) * CGFloat(position)
        return NSRect(x: bounds.width - width - edgeInset, y: y, width: width, height: thumbLength)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        let rect = thumbRect
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
        NSColor.labelColor.withAlphaComponent((hovering || dragging) ? 0.5 : 0.35).setFill()
        path.fill()
    }

    // MARK: - Visibility

    private func reveal() {
        shown = true
        fadeTimer?.invalidate()
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                animator().alphaValue = 1
            }
        }
        scheduleFade()
    }

    private func scheduleFade() {
        fadeTimer?.invalidate()
        guard !hovering, !dragging else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.fadeOut() }
        }
    }

    private func fadeOut() {
        guard !hovering, !dragging else { return }
        shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            animator().alphaValue = 0
        }
    }

    /// Invisible (or inactive) scrollbars are transparent to the mouse so
    /// clicks land in the terminal, matching native overlay behavior.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard active, shown, alphaValue > 0.01 else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard active, shown else { return }
        hovering = true
        fadeTimer?.invalidate()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        if shown {
            scheduleFade()
        }
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        guard active, shown else { return }
        let point = convert(event.locationInWindow, from: nil)
        let thumb = thumbRect
        if point.y >= thumb.minY && point.y <= thumb.maxY {
            dragOffset = point.y - thumb.minY
        } else {
            // Click on the (invisible) track: jump so the thumb centers
            // on the pointer, then continue as a drag.
            dragOffset = thumbLength / 2
        }
        dragging = true
        fadeTimer?.invalidate()
        moveThumb(toPointerY: point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        moveThumb(toPointerY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        needsDisplay = true
        scheduleFade()
    }

    private func moveThumb(toPointerY y: CGFloat) {
        let travel = trackLength - thumbLength
        guard travel > 0 else { return }
        let newPosition = Double((y - dragOffset - edgeInset) / travel)
        position = min(max(newPosition, 0), 1)
        needsDisplay = true
        onScroll?(position)
    }
}
