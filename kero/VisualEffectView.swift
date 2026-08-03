//
//  VisualEffectView.swift
//  kero
//

import AppKit
import SwiftUI

/// Native translucent material background (behind-window blur).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    /// `.followsWindowActiveState` dims the material when the window is
    /// inactive — right for a sidebar, wrong for the terminal backdrop, which
    /// should keep frosting the desktop even when Kero isn't key.
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.state = state
    }
}

/// Makes the host `NSWindow` non-opaque so a translucent terminal background
/// composites against the desktop (and the behind-window blur) instead of an
/// opaque window fill. Reverts to the standard opaque window when translucency
/// is off, so the default look is untouched.
///
/// A zero-size representable rather than a modifier so it can reach the window
/// without imposing any layout or drawing of its own.
struct WindowTranslucencyController: NSViewRepresentable {
    var isTranslucent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        if isTranslucent {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
    }
}
