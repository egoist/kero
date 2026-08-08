//
//  AgentStatusBadge.swift
//  kero
//

import AppKit
import SwiftUI

/// Native, allocation-light agent status chrome reused by panes, tabs, and
/// project rows.
///
/// The badge is the agent's presence lamp, with two deliberate tiers. Ring
/// shapes carry the ambient lifecycle — a dotted ring while starting, a live
/// spinner while working, a plain ring at rest — and stay quiet so a wall of
/// running agents never shouts. Blocked and done, the only two states that
/// also post a notification, are the only ones that earn a tinted capsule:
/// chrome weight always means "this wants you". Shape, color, motion,
/// tooltip, and accessibility label all encode the state, so status never
/// depends on color alone.
///
/// The spinner is a Core Animation transform loop, so continuous motion costs
/// no main-thread time; Reduce Motion swaps it for a static partial ring.
final class AgentStatusBadgeView: NSView {
    private enum Metrics {
        static let height: CGFloat = 15
        static let glyphBox: CGFloat = 13
        static let ringRadius: CGFloat = 4.6
        static let ringWidth: CGFloat = 1.5
        static let capsulePad: CGFloat = 3.5
        static let capsuleCountGap: CGFloat = 1.5
        static let capsuleCountTrailingPad: CGFloat = 4.5
        static let bareCountGap: CGFloat = 2.5
    }

    private static let spinKey = "kero.agentBadge.spin"

    private let capsuleLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private let imageView = NSImageView(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private var accessibilityObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    private var phase: KeroAgentPhase?
    private var count = 0
    private var countSize = NSSize.zero
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Ring geometry lives in the shape layers' own 13×13 coordinate space.
    private static let ringPath: CGPath = {
        let center = Metrics.glyphBox / 2
        return CGPath(
            ellipseIn: CGRect(
                x: center - Metrics.ringRadius,
                y: center - Metrics.ringRadius,
                width: Metrics.ringRadius * 2,
                height: Metrics.ringRadius * 2
            ),
            transform: nil
        )
    }()

    /// 270° arc with its gap at the top, so the static Reduce Motion rendering
    /// still reads as "in progress" next to idle's closed ring.
    private static let arcPath: CGPath = {
        let center = Metrics.glyphBox / 2
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: center, y: center),
            radius: Metrics.ringRadius,
            startAngle: .pi / 2,
            endAngle: -.pi,
            clockwise: true
        )
        return path
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        capsuleLayer.cornerRadius = Metrics.height / 2
        capsuleLayer.cornerCurve = .continuous
        capsuleLayer.isHidden = true

        for ring in [ringLayer, arcLayer] {
            ring.fillColor = nil
            ring.lineWidth = Metrics.ringWidth
            ring.lineCap = .round
            ring.isHidden = true
            ring.bounds = CGRect(x: 0, y: 0, width: Metrics.glyphBox, height: Metrics.glyphBox)
        }
        ringLayer.path = Self.ringPath
        arcLayer.path = Self.arcPath

        imageView.imageScaling = .scaleProportionallyDown
        imageView.isHidden = true

        // The label convenience initializer opts into Auto Layout; this view
        // lays out manually, so opt back out before AppKit engages the engine.
        countLabel.translatesAutoresizingMaskIntoConstraints = true
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        countLabel.isHidden = true

        layer?.addSublayer(capsuleLayer)
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(arcLayer)
        addSubview(imageView)
        addSubview(countLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)

        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Bind the weak self to an immutable local first: the @Sendable
            // observer block and the forwarded actor closure must not capture
            // the mutable `weak var` itself.
            let badge = self
            assumeMainActor {
                guard let badge else { return }
                badge.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                badge.updateSpinner()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    func apply(phase: KeroAgentPhase, count: Int) {
        guard self.phase != phase || self.count != count else { return }
        let previous = self.phase
        self.phase = phase
        self.count = count

        if count > 1 {
            countLabel.stringValue = "\(count)"
            let measured = countLabel.attributedStringValue.size()
            countSize = NSSize(width: ceil(measured.width), height: ceil(measured.height))
            countLabel.isHidden = false
        } else {
            countLabel.stringValue = ""
            countSize = .zero
            countLabel.isHidden = true
        }

        let description = statusDescription(phase: phase, count: count)
        toolTip = description
        setAccessibilityLabel(description)

        refreshStateAppearance()
        updateSpinner()
        invalidateIntrinsicContentSize()
        needsLayout = true

        // Pop only on a live transition into an attention state, mirroring the
        // moment the notification fires; a freshly mounted badge stays still.
        if let previous, previous != phase, isCapsule {
            popIn()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: badgeWidth, height: Metrics.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let glyphX: CGFloat = isCapsule ? Metrics.capsulePad : 0
        let glyphY = (Metrics.height - Metrics.glyphBox) / 2
        let glyphFrame = NSRect(
            x: glyphX, y: glyphY, width: Metrics.glyphBox, height: Metrics.glyphBox
        )
        let glyphCenter = CGPoint(x: glyphFrame.midX, y: glyphFrame.midY)

        capsuleLayer.frame = CGRect(x: 0, y: 0, width: badgeWidth, height: Metrics.height)
        ringLayer.position = glyphCenter
        arcLayer.position = glyphCenter
        imageView.frame = glyphFrame

        if count > 1 {
            let gap = isCapsule ? Metrics.capsuleCountGap : Metrics.bareCountGap
            countLabel.frame = NSRect(
                x: glyphFrame.maxX + gap,
                y: (Metrics.height - countSize.height) / 2,
                width: countSize.width,
                height: countSize.height
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Core Animation drops repeating animations when the layer leaves its
        // window, and can shed them while a window is occluded or the machine
        // sleeps; reinstall on arrival and whenever the window becomes visible
        // again so a days-old working badge never freezes mid-rotation.
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                let badge = self
                assumeMainActor { badge?.updateSpinner() }
            }
        }
        updateSpinner()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStateAppearance()
    }

    private var isCapsule: Bool { phase == .blocked || phase == .done }

    private var badgeWidth: CGFloat {
        let hasCount = count > 1
        if isCapsule {
            return Metrics.capsulePad + Metrics.glyphBox + (
                hasCount
                    ? Metrics.capsuleCountGap + countSize.width + Metrics.capsuleCountTrailingPad
                    : Metrics.capsulePad
            )
        }
        return Metrics.glyphBox + (hasCount ? Metrics.bareCountGap + countSize.width : 0)
    }

    /// Applies the current phase's shape, color, and capsule chrome, resolving
    /// colors against the effective appearance so layer CGColors track light
    /// and dark mode.
    private func refreshStateAppearance() {
        guard let phase else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            capsuleLayer.isHidden = true
            ringLayer.isHidden = true
            arcLayer.isHidden = true
            imageView.isHidden = true

            switch phase {
            case .created:
                ringLayer.isHidden = false
                ringLayer.lineDashPattern = [0.1, 3.51]
                ringLayer.lineWidth = Metrics.ringWidth
                ringLayer.strokeColor = NSColor.secondaryLabelColor.cgColor
                countLabel.textColor = .secondaryLabelColor
            case .working:
                ringLayer.isHidden = false
                ringLayer.lineDashPattern = nil
                ringLayer.lineWidth = Metrics.ringWidth
                ringLayer.strokeColor = NSColor.systemBlue
                    .withAlphaComponent(isDark ? 0.32 : 0.25).cgColor
                arcLayer.isHidden = false
                arcLayer.strokeColor = NSColor.systemBlue.cgColor
                countLabel.textColor = .systemBlue
            case .blocked:
                capsuleLayer.isHidden = false
                capsuleLayer.backgroundColor = NSColor.systemOrange
                    .withAlphaComponent(isDark ? 0.27 : 0.17).cgColor
                showSymbol(
                    "exclamationmark.triangle.fill",
                    pointSize: 10, weight: .semibold, tint: .systemOrange
                )
                countLabel.textColor = .systemOrange
            case .done:
                capsuleLayer.isHidden = false
                capsuleLayer.backgroundColor = NSColor.systemGreen
                    .withAlphaComponent(isDark ? 0.24 : 0.17).cgColor
                showSymbol("checkmark", pointSize: 9, weight: .bold, tint: .systemGreen)
                countLabel.textColor = .systemGreen
            case .idle:
                ringLayer.isHidden = false
                ringLayer.lineDashPattern = nil
                // Thinner than the active states, so a resting ring never
                // reads as a radio control next to the tab title.
                ringLayer.lineWidth = 1.3
                ringLayer.strokeColor = NSColor.tertiaryLabelColor.cgColor
                countLabel.textColor = .secondaryLabelColor
            case .unknown:
                showSymbol("questionmark", pointSize: 9, weight: .semibold, tint: .tertiaryLabelColor)
                countLabel.textColor = .secondaryLabelColor
            }
        }
    }

    private func showSymbol(
        _ name: String, pointSize: CGFloat, weight: NSFont.Weight, tint: NSColor
    ) {
        imageView.isHidden = false
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: pointSize, weight: weight
        )
        imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        imageView.contentTintColor = tint
    }

    private func updateSpinner() {
        if phase == .working, !reduceMotion, window != nil {
            guard arcLayer.animation(forKey: Self.spinKey) == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.2
            spin.repeatCount = .infinity
            arcLayer.add(spin, forKey: Self.spinKey)
        } else {
            arcLayer.removeAnimation(forKey: Self.spinKey)
        }
    }

    private func popIn() {
        guard !reduceMotion, let layer, bounds.width > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DScale(from, 0.55, 0.55, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.stiffness = 520
        spring.damping = 15
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "kero.agentBadge.pop")
    }

    private func statusDescription(phase: KeroAgentPhase, count: Int) -> String {
        if count <= 1 {
            return switch phase {
            case .created: String(localized: "Agent starting")
            case .working: String(localized: "Agent working")
            case .blocked: String(localized: "Agent needs attention")
            case .done: String(localized: "Agent finished")
            case .idle: String(localized: "Agent idle")
            case .unknown: String(localized: "Agent state unknown")
            }
        }
        return switch phase {
        case .created: String(localized: "\(count) agents starting")
        case .working: String(localized: "\(count) agents working")
        case .blocked: String(localized: "\(count) agents need attention")
        case .done: String(localized: "\(count) agents finished")
        case .idle: String(localized: "\(count) agents idle")
        case .unknown: String(localized: "\(count) agents in an unknown state")
        }
    }
}

/// Existing screen composition is still SwiftUI; this representable is only
/// the mount point for the AppKit view above. No status rendering or layout is
/// implemented in SwiftUI.
struct AgentStatusBadgeRepresentable: NSViewRepresentable {
    let rollup: KeroAgentRollup

    func makeNSView(context: Context) -> AgentStatusBadgeView {
        let view = AgentStatusBadgeView(frame: .zero)
        view.apply(phase: rollup.phase, count: rollup.count)
        return view
    }

    func updateNSView(_ view: AgentStatusBadgeView, context: Context) {
        view.apply(phase: rollup.phase, count: rollup.count)
    }
}
