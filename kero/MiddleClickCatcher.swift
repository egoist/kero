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

/// Invisible background that reports mouse-downs outside its bounds, plus
/// application deactivation. macOS buttons generally do not become first
/// responder, so `@FocusState` alone cannot tell an inline text field that a
/// user clicked another tab/sidebar row or the desktop.
struct OutsideClickMonitor: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> OutsideClickMonitorNSView {
        let view = OutsideClickMonitorNSView()
        view.onOutsideClick = action
        return view
    }

    func updateNSView(_ view: OutsideClickMonitorNSView, context: Context) {
        view.onOutsideClick = action
    }

    static func dismantleNSView(_ view: OutsideClickMonitorNSView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor
final class OutsideClickMonitorNSView: NSView {
    var onOutsideClick: (() -> Void)?

    private var eventMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Local monitors run synchronously on AppKit's main event thread.
            // Keep non-Sendable NSEvent inside an unchecked wrapper while
            // crossing `assumeIsolated`'s generic boundary.
            let input = MainThreadMouseEvent(event)
            let output: MainThreadMouseEvent = MainActor.assumeIsolated {
                guard let self, let event = input.value else { return input }
                let isInside: Bool
                if event.window === self.window {
                    isInside = self.bounds.contains(
                        self.convert(event.locationInWindow, from: nil)
                    )
                } else {
                    isInside = false
                }
                if !isInside {
                    self.reportOutsideClick()
                }
                return input
            }
            return output.value
        }

        for name in [
            NSWindow.didResignKeyNotification,
            NSApplication.didResignActiveNotification,
        ] {
            focusObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: name == NSWindow.didResignKeyNotification ? window : nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportOutsideClick()
                }
            })
        }
    }

    /// This view observes events globally within the app; it never takes a hit
    /// away from the SwiftUI control layered above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        focusObservers.removeAll()
    }

    private func reportOutsideClick() {
        // Leave the current event free to reach its intended target. Capture
        // the closure now because SwiftUI may dismantle this view first.
        let action = onOutsideClick
        DispatchQueue.main.async {
            action?()
        }
    }

    deinit {
        // `deinit` is nonisolated, so it cannot call the @MainActor helper.
        // Mirror TabSwitcherMonitorView and release the AppKit tokens here.
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private struct MainThreadMouseEvent: @unchecked Sendable {
    let value: NSEvent?

    init(_ value: NSEvent?) {
        self.value = value
    }
}
