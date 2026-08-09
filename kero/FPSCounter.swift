//
//  FPSCounter.swift
//  kero
//

import AppKit
import Combine
import QuartzCore

/// Counts CADisplayLink callbacks to report how often the window can actually
/// present a new frame — the UI's real redraw cadence, not elapsed time a
/// timer would measure. A debug aid: the counter exists only while the sidebar
/// badge it feeds is visible, and pauses while the app is inactive so a
/// backgrounded rate can't show as a bogus low FPS.
@MainActor
final class FPSCounter: ObservableObject {
    @Published private(set) var fps = 0

    private var displayLink: CADisplayLink?
    private var framesInWindow = 0
    private var windowStart = CACurrentMediaTime()
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard displayLink == nil else { return }
        // CADisplayLink retains its target, so it gets a weak proxy instead of
        // the counter itself; stop() invalidates the link and breaks the cycle.
        // macOS creates the link from a screen rather than an initializer.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(
            target: FPSDisplayLinkProxy(counter: self),
            selector: #selector(FPSDisplayLinkProxy.tick(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
        resetWindow()

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Bind the weak self to an immutable local first: the
            // @Sendable observer block and the forwarded actor closure
            // must not capture the mutable `weak var` itself.
            let counter = self
            assumeMainActor { counter?.setPaused(true) }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let counter = self
            assumeMainActor { counter?.setPaused(false) }
        })
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        fps = 0
    }

    /// One display-refresh callback.
    func tick() {
        framesInWindow += 1
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        fps = Int((Double(framesInWindow) / elapsed).rounded())
        framesInWindow = 0
        windowStart = now
    }

    private func setPaused(_ paused: Bool) {
        guard let link = displayLink else { return }
        link.isPaused = paused
        // Start a fresh window on resume; the pause itself doesn't count.
        if !paused { resetWindow() }
    }

    private func resetWindow() {
        framesInWindow = 0
        windowStart = CACurrentMediaTime()
    }
}

/// CADisplayLink strongly retains its target; this proxy keeps that reference
/// out of the counter so stop() can break the cycle. Ticks arrive on the main
/// run loop, where the link was added.
private final class FPSDisplayLinkProxy: NSObject {
    private weak var counter: FPSCounter?

    init(counter: FPSCounter) {
        self.counter = counter
    }

    @objc func tick(_ link: CADisplayLink) {
        assumeMainActor { counter?.tick() }
    }
}
