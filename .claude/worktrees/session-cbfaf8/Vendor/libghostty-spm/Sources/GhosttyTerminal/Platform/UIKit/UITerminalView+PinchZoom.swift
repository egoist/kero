//
//  UITerminalView+PinchZoom.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import UIKit

    extension UITerminalView {
        private static let scaleStepThreshold: CGFloat = 0.1

        func setupPinchZoomGesture() {
            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handlePinchGesture(_:))
            )
            addGestureRecognizer(pinch)
        }

        @objc func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                lastPinchScale = gesture.scale
                TerminalDebugLog.log(
                    .actions,
                    "pinch began scale=\(String(format: "%.3f", gesture.scale)) fontSize=\(currentFontSize)"
                )

            case .changed:
                let delta = gesture.scale - lastPinchScale

                let steps = Int(delta / Self.scaleStepThreshold)
                guard steps != 0 else { return }

                lastPinchScale += CGFloat(steps) * Self.scaleStepThreshold
                TerminalDebugLog.log(
                    .actions,
                    "pinch changed scale=\(String(format: "%.3f", gesture.scale)) delta=\(String(format: "%.3f", delta)) steps=\(steps)"
                )

                var changed = false
                if steps > 0 {
                    for _ in 0 ..< steps {
                        guard currentFontSize < Self.maxFontSize else { break }
                        surface?.performBindingAction("increase_font_size:1")
                        currentFontSize += 1
                        changed = true
                    }
                } else {
                    for _ in 0 ..< abs(steps) {
                        guard currentFontSize > Self.minFontSize else { break }
                        surface?.performBindingAction("decrease_font_size:1")
                        currentFontSize -= 1
                        changed = true
                    }
                }

                if changed {
                    core.synchronizeMetrics()
                    refreshTextInputGeometry(reason: "pinch-zoom")
                    TerminalDebugLog.log(
                        .actions,
                        "pinch applied fontSize=\(currentFontSize)"
                    )
                }

            case .ended, .cancelled, .failed:
                lastPinchScale = 1.0
                TerminalDebugLog.log(
                    .actions,
                    "pinch ended state=\(gesture.state.rawValue) fontSize=\(currentFontSize)"
                )

            default:
                break
            }
        }
    }
#endif
