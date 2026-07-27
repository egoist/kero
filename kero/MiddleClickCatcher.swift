//
//  MiddleClickCatcher.swift
//  kero
//

import AppKit
import SwiftUI

/// Invisible overlay that fires on middle-mouse click. Left-button hits pass
/// through (`hitTest` returns nil) so SwiftUI buttons underneath still select
/// and drag; only `.otherMouse*` events land here — the browser-tab close
/// convention without stealing the primary click.
struct MiddleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        let view = MiddleClickNSView()
        view.onMiddleClick = action
        return view
    }

    func updateNSView(_ view: MiddleClickNSView, context: Context) {
        view.onMiddleClick = action
    }
}

final class MiddleClickNSView: NSView {
    var onMiddleClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Transparent to layout; we only participate in hit-testing for
        // middle-button events (see hitTest).
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return self
        default:
            return nil
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        onMiddleClick?()
    }
}
