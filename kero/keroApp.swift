//
//  keroApp.swift
//  kero
//

import SwiftUI

@main
struct keroApp: App {
    // Held here so Sparkle starts at launch and background checks run even if
    // the menu is never opened.
    @StateObject private var updater = Updater.shared

    init() {
        TerminalFont.registerBundledFonts()
        TerminalNotificationService.shared.configure()
    }

    var body: some Scene {
        WindowGroup("kero", id: "main") {
            WindowRootView()
        }
        .windowStyle(.hiddenTitleBar)
        // Keep title-bar dragging away from interactive tabs. The empty
        // header surfaces opt in explicitly through WindowDragArea.
        .windowBackgroundDragBehavior(.disabled)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
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

            Button("Close Pane") {
                // Cmd-W is app-wide: close a pane only when a main window with
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

        CommandGroup(after: .pasteboard) {
            Button("Clear Terminal") {
                manager?.clearActiveTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(manager?.canClearActiveTerminal != true)
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

            Button("Toggle Left Sidebar") {
                manager?.toggleLeftSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(manager == nil)

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
            Button("Split Right") {
                manager?.splitRight()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(manager?.canSplit != true)

            Button("Split Down") {
                manager?.splitDown()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(manager?.canSplit != true)

            Button("Split Left") {
                manager?.splitLeft()
            }
            .disabled(manager?.canSplit != true)

            Button("Split Up") {
                manager?.splitUp()
            }
            .disabled(manager?.canSplit != true)

            Divider()

            Button("Focus Pane Left") {
                manager?.focusPaneLeft()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Focus Pane Right") {
                manager?.focusPaneRight()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Focus Pane Up") {
                manager?.focusPaneUp()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Button("Focus Pane Down") {
                manager?.focusPaneDown()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(manager == nil)

            Divider()

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

            Divider()

            ForEach(Array((manager?.selectedProject?.tabs ?? []).prefix(9).enumerated()), id: \.element.id) { index, tab in
                Button(tab.focusedContent?.title ?? "Tab \(index + 1)") {
                    manager?.selectTab(index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .shift])
            }
        }
    }
}
