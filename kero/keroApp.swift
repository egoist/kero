//
//  keroApp.swift
//  kero
//

import SwiftUI

@main
struct keroApp: App {
    init() {
        TerminalFont.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("kero", id: "main") {
            WindowRootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            KeroCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Root of one terminal window. Each window owns its own manager, which
/// claims the next unclaimed window snapshot; the first window to appear
/// reopens windows for any snapshots left over.
private struct WindowRootView: View {
    @StateObject private var manager = TerminalManager()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(manager: manager)
            .focusedSceneObject(manager)
            .onAppear {
                TerminalManager.openRestoredWindows {
                    openWindow(id: "main")
                }
            }
            .onDisappear {
                manager.windowClosed()
            }
    }
}

/// Menu commands routed to the focused window's manager.
private struct KeroCommands: Commands {
    @FocusedObject private var manager: TerminalManager?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                manager?.newProject()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(manager == nil)

            Button("New Session") {
                manager?.newSession()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(manager == nil)

            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Close Tab") {
                // Cmd-W is app-wide: close a tab only when a main window with
                // an open project is key. Otherwise close the key window
                // itself — a non-main window (e.g. Settings), or a main window
                // showing the empty "No open projects" state with no tab left.
                if let manager, manager.selectedProject != nil,
                   NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true {
                    manager.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                manager?.saveSelectedFile()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager == nil)
        }

        // Frees ⌘P from the default Print item for the command palette.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                manager?.toggleCommandPalette()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(manager == nil)

            Divider()

            Button("Toggle Sidebar") {
                manager?.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Files Panel") {
                manager?.togglePanel(.files)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Git Panel") {
                manager?.togglePanel(.git)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button("Toggle Info Panel") {
                manager?.togglePanel(.info)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)
        }

        CommandMenu("Projects") {
            Button("Next Project") {
                manager?.selectNextProject()
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Previous Project") {
                manager?.selectPreviousProject()
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(manager == nil)

            Divider()

            ForEach(Array((manager?.projects ?? []).prefix(9).enumerated()), id: \.element.id) { index, project in
                Button(project.name) {
                    manager?.selectProject(index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }

        CommandMenu("Tabs") {
            Button("Next Tab") {
                manager?.selectNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Button("Previous Tab") {
                manager?.selectPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(manager == nil)
        }
    }
}
