//
//  TerminalViewRepresentable@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import SwiftUI

    extension TerminalViewRepresentable: NSViewRepresentable {
        func makeNSView(context _: Context) -> TerminalView {
            let view = TerminalView(frame: .zero)
            configureView(view, initial: true)
            view.onFocusChange = { focused in
                focusBinding.setFocused(focused)
            }
            Self.synchronizeFocus(view, with: focusBinding)
            return view
        }

        func updateNSView(_ view: TerminalView, context _: Context) {
            configureView(view, initial: false)
            view.onFocusChange = { focused in
                focusBinding.setFocused(focused)
            }
            Self.synchronizeFocus(view, with: focusBinding)
        }

        static func dismantleNSView(_ view: TerminalView, coordinator _: ()) {
            view.onFocusChange = nil
        }
    }
#endif
