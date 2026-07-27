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
    private var filter: NSObject?

    func install(radius: Double) {
        wantsLayer = true
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let blur = filterClass
                  .perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                  .takeUnretainedValue() as? NSObject
        else { return }
        blur.setValue(radius, forKey: "inputRadius")
        blur.setValue(true, forKey: "enabled")
        let layer = backdropClass.init()
        // colorSaturate matches the second half of the material's own filter
        // stack (sdrNormalize · gaussianBlur · colorSaturate), so the custom
        // radius keeps the familiar frosted saturation boost.
        var filters: [Any] = [blur]
        if let saturate = filterClass
            .perform(NSSelectorFromString("filterWithType:"), with: "colorSaturate")?
            .takeUnretainedValue() as? NSObject {
            saturate.setValue(1.5, forKey: "inputAmount")
            saturate.setValue(true, forKey: "enabled")
            filters.append(saturate)
        }
        layer.filters = filters
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        backdrop = layer
        filter = blur
    }

    func setRadius(_ radius: Double) {
        guard let backdrop, let filter else { return }
        filter.setValue(radius, forKey: "inputRadius")
        // Mutating a filter in place isn't observed; reassigning the array
        // recommits it to the render tree.
        backdrop.filters = backdrop.filters
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
    }
}
