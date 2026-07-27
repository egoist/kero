//
//  VisualEffectView.swift
//  kero
//

import AppKit
import SwiftUI

/// Native translucent material background (behind-window blur).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
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

/// Behind-window gaussian blur with a configurable radius, for the
/// `background-blur` setting. The system exposes no adjustable-radius API:
/// `NSVisualEffectView`'s blur is fixed, and the window server's
/// `CGSSetWindowBackgroundBlurRadius` (Ghostty's mechanism) succeeds but
/// renders nothing under macOS 26's compositor — as does mutating the
/// gaussian filter inside the material's own backdrop. A backdrop layer we
/// create ourselves still honors its filters, so this hosts one carrying a
/// gaussian at the configured radius. Sits beneath the window material,
/// which then samples the pre-blurred composite. Fails soft: if either
/// private class disappears, the view stays empty and the window keeps the
/// material's fixed blur.
struct BackdropBlurView: NSViewRepresentable {
    var radius: Double

    func makeNSView(context: Context) -> BackdropBlurHostView {
        let view = BackdropBlurHostView()
        view.install(radius: radius)
        return view
    }

    func updateNSView(_ view: BackdropBlurHostView, context: Context) {
        view.setRadius(radius)
    }

    /// Whether the private classes this view depends on resolve — the
    /// caller keeps the stock material when they don't, so a future OS
    /// removing them degrades to the fixed system blur.
    static var isSupported: Bool {
        NSClassFromString("CABackdropLayer") != nil && NSClassFromString("CAFilter") != nil
    }
}

final class BackdropBlurHostView: NSView {
    private var backdrop: CALayer?
    private var currentRadius: Double?

    func install(radius: Double) {
        wantsLayer = true
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            return
        }
        let layer = backdropClass.init()
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        backdrop = layer
        setRadius(radius)
    }

    func setRadius(_ radius: Double) {
        guard let backdrop, radius != currentRadius else { return }
        // Fresh filter instances every time: the render server snapshots
        // filter parameters when the array is assigned, so mutating an
        // installed filter in place changes nothing (the same trap that
        // makes the system material's own gaussian un-adjustable).
        backdrop.filters = Self.makeFilters(radius: radius)
        currentRadius = radius
    }

    /// gaussianBlur at the configured radius, plus colorSaturate matching
    /// the second half of the material's own stack (sdrNormalize ·
    /// gaussianBlur · colorSaturate) so the frosted saturation boost stays.
    private static func makeFilters(radius: Double) -> [Any] {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else {
            return []
        }
        func make(_ type: String, _ key: String, _ value: Double) -> NSObject? {
            guard let filter = filterClass
                .perform(NSSelectorFromString("filterWithType:"), with: type)?
                .takeUnretainedValue() as? NSObject else { return nil }
            filter.setValue(value, forKey: key)
            filter.setValue(true, forKey: "enabled")
            return filter
        }
        return [
            make("gaussianBlur", "inputRadius", radius),
            make("colorSaturate", "inputAmount", 1.5),
        ].compactMap { $0 }
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
    }
}
