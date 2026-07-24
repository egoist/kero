//
//  TerminalViewRepresentable@UIKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    extension TerminalViewRepresentable: UIViewRepresentable {
        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context viewContext: Context) -> TerminalView {
            let view = TerminalView(frame: .zero)
            configureView(view, initial: true)
            viewContext.coordinator.attach(to: view, focusBinding: focusBinding)
            Self.synchronizeFocus(view, with: focusBinding)
            return view
        }

        func updateUIView(_ view: TerminalView, context viewContext: Context) {
            configureView(view, initial: false)
            viewContext.coordinator.attach(to: view, focusBinding: focusBinding)
            Self.synchronizeFocus(view, with: focusBinding)
        }

        static func dismantleUIView(_: TerminalView, coordinator: Coordinator) {
            coordinator.detach()
        }

        @MainActor
        final class Coordinator {
            private weak var view: TerminalView?
            private var focusBinding: TerminalFocusBinding?

            func attach(
                to view: TerminalView,
                focusBinding: TerminalFocusBinding?
            ) {
                self.view = view
                self.focusBinding = focusBinding
                view.onFocusChange = { [weak self] focused in
                    self?.focusBinding.setFocused(focused)
                }
            }

            func detach() {
                view?.onFocusChange = nil
                focusBinding = nil
                view = nil
            }
        }
    }
#endif
