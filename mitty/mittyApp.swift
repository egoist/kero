//
//  mittyApp.swift
//  mitty
//

import SwiftUI

@main
struct mittyApp: App {
    @StateObject private var manager = TerminalManager()

    init() {
        TerminalFont.registerBundledFonts()
    }

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

                Button("Close Tab") {
                    // Cmd-W is app-wide: only close a tab when the main window is
                    // key; otherwise close the key window (e.g. Settings).
                    if let keyWindow = NSApp.keyWindow,
                       keyWindow.identifier?.rawValue.hasPrefix("main") != true {
                        keyWindow.performClose(nil)
                    } else {
                        manager.closeSelectedTab()
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    manager.saveSelectedFile()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            // Frees ⌘P from the default Print item for the command palette.
            CommandGroup(replacing: .printItem) {}

            CommandGroup(after: .sidebar) {
                Button("Command Palette…") {
                    manager.toggleCommandPalette()
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

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

            CommandMenu("Tabs") {
                Button("Next Tab") {
                    manager.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    manager.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
