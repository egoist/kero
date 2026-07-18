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
                Button("New Project") {
                    manager.newProject()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Session") {
                    manager.newSession()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Session") {
                    manager.closeSelectedSession()
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

            CommandMenu("Projects") {
                Button("Next Project") {
                    manager.selectNextProject()
                }
                .keyboardShortcut("]", modifiers: [.command, .option])

                Button("Previous Project") {
                    manager.selectPreviousProject()
                }
                .keyboardShortcut("[", modifiers: [.command, .option])

                Divider()

                ForEach(Array(manager.projects.prefix(9).enumerated()), id: \.element.id) { index, project in
                    Button(project.name) {
                        manager.selectProject(index: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }

            CommandMenu("Sessions") {
                Button("Next Session") {
                    manager.selectNextSession()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Session") {
                    manager.selectPreviousSession()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
    }
}
