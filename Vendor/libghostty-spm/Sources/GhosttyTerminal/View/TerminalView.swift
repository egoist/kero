//
//  TerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import UIKit

    public typealias TerminalView = UITerminalView
#elseif canImport(AppKit)
    import AppKit

    public typealias TerminalView = AppTerminalView
#endif
