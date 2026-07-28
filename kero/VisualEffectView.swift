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

/// System material plus an AppKit-owned color wash. SwiftUI fills can be
/// reordered beneath representable views, so translucent callers that need a
/// reliable tint keep it in this native view hierarchy.
struct TintedVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var state: NSVisualEffectView.State = .active
    var tint: NSColor?

    func makeNSView(context: Context) -> MaterialEffectView {
        let view = MaterialEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = state
        view.setTint(tint)
        return view
    }

    func updateNSView(_ view: MaterialEffectView, context: Context) {
        view.material = material
        view.state = state
        view.setTint(tint)
    }
}

final class MaterialEffectView: NSVisualEffectView {
    private let tintView = PassthroughTintView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTint(_ tint: NSColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintView.layer?.backgroundColor = tint?.cgColor
        CATransaction.commit()
    }
}

private final class PassthroughTintView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Behind-window gaussian blur with a configurable radius, for the
/// `background-blur` setting. The system exposes no adjustable-radius API:
/// `NSVisualEffectView`'s blur is fixed, and the window server's
/// `CGSSetWindowBackgroundBlurRadius` (Ghostty's mechanism) succeeds but
/// renders nothing under macOS 26's compositor — as does mutating the
/// gaussian filter inside the material's own backdrop. A backdrop layer we
/// create ourselves still honors its filters, so this hosts one carrying a
/// gaussian at the configured radius, with the theme tint in the same native
/// layer stack so SwiftUI ordering cannot bury it. Fails soft: callers keep
/// the fixed system material if the private backdrop or gaussian factory is
/// unavailable.
struct BackdropBlurView: NSViewRepresentable {
    var radius: Double
    /// Theme tint composited directly above the backdrop. SwiftUI-drawn
    /// background fills render beneath representable views, so a tint
    /// declared as a sibling background never shows over the backdrop —
    /// it has to live inside the host's own layer stack.
    var tint: NSColor?

    func makeNSView(context: Context) -> BackdropBlurHostView {
        let view = BackdropBlurHostView()
        view.install(radius: radius, tint: tint)
        return view
    }

    func updateNSView(_ view: BackdropBlurHostView, context: Context) {
        view.set(radius: radius, tint: tint)
    }

    static func dismantleNSView(
        _ view: BackdropBlurHostView, coordinator: ()
    ) {
        view.invalidateScheduledRebuilds()
    }

    /// Whether the private classes this view depends on resolve — the
    /// caller keeps the stock material when they don't, so a future OS
    /// removing them degrades to the fixed system blur.
    static var isSupported: Bool {
        BackdropBlurHostView.isSupported
    }
}

@MainActor
final class BackdropBlurHostView: NSView {
    private nonisolated static let minimumRebuildInterval: TimeInterval = 0.15
    private nonisolated static let trailingRebuildDelay: TimeInterval = 0.2
    private nonisolated static let verificationRebuildDelay: TimeInterval = 0.5
    private nonisolated static let settleRetryDelay: TimeInterval = 0.25

    /// Class lookup alone is insufficient: an OS can leave `CAFilter`
    /// present while removing the gaussian factory. Test the operation the
    /// host actually needs so callers keep the stock material on failure.
    fileprivate static let isSupported: Bool = {
        guard NSClassFromString("CABackdropLayer") is CALayer.Type else {
            return false
        }
        return makeFilters(radius: 1) != nil
    }()

    private var backdrop: CALayer?
    private var tintLayer: CALayer?
    private var currentRadius: Double?
    private var currentTint: NSColor?
    private var requestedRadius: Double?
    private var requestedTint: NSColor?
    private var lastRebuildUptime: TimeInterval?
    private var lastTrackingUptime: TimeInterval = 0
    private var trailingRebuild: Timer?
    private var verificationRebuild: Timer?
    private var scheduleGeneration = 0

    func install(radius: Double, tint: NSColor?) {
        wantsLayer = true
        cancelScheduledRebuilds()
        requestedRadius = radius
        requestedTint = tint
        rebuildRequestedState()
    }

    func setRadius(_ radius: Double) {
        guard radius != requestedRadius else { return }
        requestedRadius = radius
        requestRebuild()
    }

    func setTint(_ tint: NSColor?) {
        guard tint != requestedTint else { return }
        requestedTint = tint
        requestRebuild()
    }

    func set(radius: Double, tint: NSColor?) {
        guard radius != requestedRadius || tint != requestedTint else { return }
        requestedRadius = radius
        requestedTint = tint
        requestRebuild()
    }

    fileprivate func invalidateScheduledRebuilds() {
        cancelScheduledRebuilds()
    }

    /// A slider can deliver dozens of changes per second. Reinstalling at
    /// that rate has been observed to leave the final backdrop registered
    /// but no longer capturing, as if the window server never settled its
    /// capture scope. Keep a leading-edge update for responsiveness, cap
    /// rebuilds during the stream, then install the final requested state
    /// once the stream has been quiet long enough for the server to settle.
    private func requestRebuild() {
        cancelScheduledRebuilds()
        let now = ProcessInfo.processInfo.systemUptime
        let tracking = RunLoop.main.currentMode == .eventTracking
        if tracking { lastTrackingUptime = now }
        if tracking || (lastRebuildUptime.map { now - $0 < Self.minimumRebuildInterval } ?? false) {
            scheduleTrailingRebuild()
        } else {
            rebuildRequestedState()
        }
    }

    /// A timer that fires noticeably later than scheduled was parked while
    /// the run loop sat in event-tracking mode (a slider drag). Installing a
    /// backdrop in the first moments after tracking ends lands dead the same
    /// way installing during it does, so a late fire — or one close on the
    /// heels of a change made during tracking — must re-arm instead of
    /// installing.
    private func isSettled(scheduledFor: TimeInterval) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return now - scheduledFor < 0.1 && now - lastTrackingUptime > 0.3
    }

    /// Both delayed rebuilds run from timers added to the default run-loop
    /// mode ONLY. During a slider drag the main run loop sits in event-
    /// tracking mode, and a backdrop installed from that mode lands
    /// permanently stale — the drag's value stream ends up rendering as
    /// clear glass until the window is refocused. Default-mode timers stall
    /// while the mouse is held and fire the moment tracking ends, so the
    /// final install always happens on a clean default-mode pass.
    private func scheduleTrailingRebuild(
        delay: TimeInterval = trailingRebuildDelay
    ) {
        let generation = scheduleGeneration
        let scheduledFor = ProcessInfo.processInfo.systemUptime + delay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scheduleGeneration == generation else { return }
                self.trailingRebuild = nil
                guard self.isSettled(scheduledFor: scheduledFor) else {
                    self.scheduleTrailingRebuild(delay: Self.settleRetryDelay)
                    return
                }
                guard self.rebuildRequestedState() else { return }
                self.scheduleVerificationRebuild()
            }
        }
        trailingRebuild = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    /// One final fresh install gives the compositor another chance to acquire
    /// a live capture scope if the trailing install raced server-side cleanup
    /// from the burst. Any new setting change cancels this stale retry.
    private func scheduleVerificationRebuild(
        delay: TimeInterval = verificationRebuildDelay
    ) {
        let generation = scheduleGeneration
        let scheduledFor = ProcessInfo.processInfo.systemUptime + delay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scheduleGeneration == generation else { return }
                self.verificationRebuild = nil
                guard self.isSettled(scheduledFor: scheduledFor) else {
                    self.scheduleVerificationRebuild(delay: Self.settleRetryDelay)
                    return
                }
                self.rebuildRequestedState()
            }
        }
        verificationRebuild = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private func cancelScheduledRebuilds() {
        scheduleGeneration &+= 1
        trailingRebuild?.invalidate()
        trailingRebuild = nil
        verificationRebuild?.invalidate()
        verificationRebuild = nil
    }

    @discardableResult
    private func rebuildRequestedState() -> Bool {
        guard let requestedRadius else { return false }
        guard rebuild(radius: requestedRadius, tint: requestedTint) else {
            return false
        }
        lastRebuildUptime = ProcessInfo.processInfo.systemUptime
        return true
    }

    /// Live mutation of an attached backdrop is unreliable under macOS 26's
    /// compositor — replacing the filters array, writing through the
    /// documented `filters.<name>.inputRadius` key path, and recoloring a
    /// sibling tint layer have each been observed to leave the rendered
    /// output frozen at its install-time state while the model (and even the
    /// presentation tree) report the new values. Fresh installs render
    /// correctly, so each applied state rebuilds the sublayers from scratch
    /// inside one transaction.
    @discardableResult
    private func rebuild(radius: Double, tint: NSColor?) -> Bool {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filters = Self.makeFilters(radius: radius)
        else { return false }
        let oldBackdrop = backdrop
        let oldTint = tintLayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = backdropClass.init()
        layer.filters = filters
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        backdrop = layer
        let tinted = CALayer()
        tinted.backgroundColor = tint?.cgColor
        tinted.frame = bounds
        self.layer?.addSublayer(tinted)
        tintLayer = tinted
        CATransaction.commit()
        // Remove the replaced pair only after the fresh one is committed:
        // tearing down the window's sole established capture in the same
        // transaction as the new install risks a moment with no working
        // backdrop if the new one fails to start capturing. With overlap,
        // a failed install degrades to the previous blur, not clear glass.
        if oldBackdrop != nil || oldTint != nil {
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                oldBackdrop?.removeFromSuperlayer()
                oldTint?.removeFromSuperlayer()
                CATransaction.commit()
            }
        }
        currentRadius = radius
        currentTint = tint
        if window?.isKeyWindow == false, NSApp.isActive {
            needsKeyRefresh = true
        } else {
            needsKeyRefresh = false
        }
        return true
    }

    /// Backdrops attached while another window of an active app holds key
    /// have been observed to start dead, reviving only when this window
    /// becomes key. Rebuild once at that moment so any such install heals
    /// itself the way a manual refocus does.
    private var needsKeyRefresh = false
    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.needsKeyRefresh else { return }
                self.needsKeyRefresh = false
                self.rebuildRequestedState()
            }
        }
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
        tintLayer?.frame = bounds
    }
}
