//
//  WindowChrome.swift
//  kero
//

import AppKit
import SwiftUI

/// Keeps the traffic-light buttons aligned with the app's 38pt header bar:
/// 20pt leading, vertically centered on the header's center line. AppKit
/// re-lays the buttons out on various events, so we re-apply after each.
struct WindowChromeAccessor: NSViewRepresentable {
    static let buttonCenterY: CGFloat = 21
    static let buttonLeading: CGFloat = 16
    static let buttonSpacing: CGFloat = 20

    private let backgroundOpacity: Double
    private let onAttach: (NSWindow) -> Void

    init(
        backgroundOpacity: Double = 1,
        onAttach: @escaping (NSWindow) -> Void = { _ in }
    ) {
        self.backgroundOpacity = backgroundOpacity
        self.onAttach = onAttach
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(backgroundOpacity: backgroundOpacity, onAttach: onAttach)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.setBackgroundOpacity(backgroundOpacity)
        if let window = view.window {
            context.coordinator.attach(window)
        }
    }

    @MainActor
    final class Coordinator {
        private struct OpaqueBackground {
            let isOpaque: Bool
            let color: NSColor?
        }

        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var backgroundOpacity: Double
        private var opaqueBackground: OpaqueBackground?
        private let onAttach: (NSWindow) -> Void

        init(
            backgroundOpacity: Double,
            onAttach: @escaping (NSWindow) -> Void
        ) {
            self.backgroundOpacity = backgroundOpacity
            self.onAttach = onAttach
        }

        func setBackgroundOpacity(_ opacity: Double) {
            backgroundOpacity = opacity
            updateWindowBackground()
        }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            restoreOpaqueBackground()
            self.window = window
            onAttach(window)
            updateWindowBackground()
            // Interactive controls occupy the title-bar region. Disable the
            // server-side title-bar drag entirely; WindowDragArea is the only
            // surface that opts into moving the window.
            window.isMovable = false
            reposition()
            // The initial system layout can land after us; catch up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reposition() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reposition() }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reposition()
                    }
                })
            }
        }

        /// Capture and restore AppKit's exact opaque-window state so the
        /// default path is untouched, including after live opacity changes.
        private func updateWindowBackground() {
            guard let window else { return }
            if backgroundOpacity < AppSettings.defaultBackgroundOpacity {
                if opaqueBackground == nil {
                    opaqueBackground = OpaqueBackground(
                        isOpaque: window.isOpaque,
                        color: window.backgroundColor
                    )
                }
                window.isOpaque = false
                window.backgroundColor = .clear
            } else {
                restoreOpaqueBackground()
            }
        }

        private func restoreOpaqueBackground() {
            guard let window, let opaqueBackground else { return }
            window.isOpaque = opaqueBackground.isOpaque
            window.backgroundColor = opaqueBackground.color
            self.opaqueBackground = nil
        }

        private func reposition() {
            guard let window else { return }
            window.isMovable = false
            guard !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview
                else { continue }
                let centerInWindow = NSPoint(
                    x: WindowChromeAccessor.buttonLeading + CGFloat(index) * WindowChromeAccessor.buttonSpacing + button.frame.width / 2,
                    y: window.frame.height - WindowChromeAccessor.buttonCenterY
                )
                let center = superview.convert(centerInWindow, from: nil)
                let origin = NSPoint(
                    x: center.x - button.frame.width / 2,
                    y: center.y - button.frame.height / 2
                )
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// A deliberate window-moving surface. Interactive header controls are kept
/// outside this view so their own drag gestures receive the full mouse stream.
///
/// Double-clicking runs the standard title-bar action (zoom / minimize per
/// System Settings) — behavior our non-movable, hidden title bar would
/// otherwise lose. The tap is simultaneous with the drag: a stationary
/// double-click never registers a move, so the two don't conflict.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                NSApp.keyWindow?.performTitlebarDoubleClickAction()
            })
            .allowsWindowActivationEvents()
    }
}

extension NSWindow {
    /// Mirrors what a standard title bar does on double-click, honoring the
    /// "Double-click a window's title bar to" setting in System Settings.
    /// The global default is absent when set to Zoom, which is the default.
    func performTitlebarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default: // "Maximize" or unset
            performZoom(nil)
        }
    }
}
