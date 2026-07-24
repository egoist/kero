//
//  main.swift
//  GhosttyTerminalApp
//
//  Created by qaq on 19/3/2026.
//

import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    fatalError()
}
