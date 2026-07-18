//
//  mittyApp.swift
//  mitty
//

import SwiftUI

@main
struct mittyApp: App {
    @StateObject private var manager = TerminalManager()

    var body: some Scene {
        Window("mitty", id: "main") {
            ContentView(manager: manager)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    manager.newSession()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Session") {
                    manager.closeSelected()
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    manager.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Toggle Files Panel") {
                    manager.togglePanel(.files)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Toggle Git Panel") {
                    manager.togglePanel(.git)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            CommandMenu("Sessions") {
                Button("Next Session") {
                    manager.selectNext()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Session") {
                    manager.selectPrevious()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(Array(manager.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
                    Button(session.title) {
                        manager.select(index: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}
