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
    private static let blurFilterName = "keroBackgroundBlur"

    private var backdrop: CALayer?
    private var currentRadius: Double?

    func install(radius: Double) {
        wantsLayer = true
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filters = Self.makeFilters(radius: radius)
        else {
            return
        }
        let layer = backdropClass.init()
        layer.filters = filters
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        backdrop = layer
        currentRadius = radius
    }

    func setRadius(_ radius: Double) {
        guard let backdrop, radius != currentRadius else { return }
        // Replacing this animatable array briefly commits the new filters,
        // then the attached backdrop restores its previous filter state.
        // Addressing the named filter through its layer is the observable
        // update path; changing the filter object itself is not.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.setValue(
            radius,
            forKeyPath: "filters.\(Self.blurFilterName).inputRadius"
        )
        CATransaction.commit()
        currentRadius = radius
    }

    /// gaussianBlur at the configured radius, plus colorSaturate matching
    /// the second half of the material's own stack (sdrNormalize ·
    /// gaussianBlur · colorSaturate) so the frosted saturation boost stays.
    private static func makeFilters(radius: Double) -> [Any]? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else {
            return nil
        }
        func make(_ type: String, _ key: String, _ value: Double) -> NSObject? {
            guard let filter = filterClass
                .perform(NSSelectorFromString("filterWithType:"), with: type)?
                .takeUnretainedValue() as? NSObject else { return nil }
            filter.setValue(value, forKey: key)
            filter.setValue(true, forKey: "enabled")
            return filter
        }
        guard let blur = make("gaussianBlur", "inputRadius", radius) else {
            return nil
        }
        blur.setValue(Self.blurFilterName, forKey: "name")
        // Without edge normalization the kernel's weights fall off where it
        // samples past the layer bounds, reading as a vignette of weaker
        // blur along the window edges.
        blur.setValue(true, forKey: "inputNormalizeEdges")
        var filters: [Any] = [blur]
        if let saturate = make("colorSaturate", "inputAmount", 1.5) {
            filters.append(saturate)
        }
        return filters
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
    }
}
