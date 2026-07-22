//
//  ContentView.swift
//  kero
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            if manager.isLeftSidebarVisible {
                SidebarView(manager: manager)
            }

            VStack(spacing: 0) {
                AppKitHeaderView(manager: manager)
                    .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)

                ZStack {
                    // Diff panes stay mounted while unselected: removing one
                    // would pull its NSHostingView out of the window, which
                    // tears down and re-creates the WKWebView inside (losing
                    // the rendered diff and scroll position). Unselected ones
                    // just sit covered by the active tab's opaque pane layer.
                    // Diffs are always their own single-pane tab, so a selected
                    // diff fills the whole content area, unchanged.
                    if let project = manager.selectedProject {
                        ForEach(project.diffPlacements, id: \.diff.id) { placement in
                            DiffViewerView(
                                diff: placement.diff,
                                isSelected: project.selectedTabID == placement.tabID
                            )
                            .background(Color(nsColor: Theme.background))
                            .allowsHitTesting(project.selectedTabID == placement.tabID)
                            .zIndex(project.selectedTabID == placement.tabID ? 1 : 0)
                        }
                    }
                    Group {
                        if let tab = manager.selectedProject?.selectedTab {
                            PaneLayoutView(tab: tab, onSplit: { manager.split(toward: $0) })
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Opaque so the pane gaps hide the unselected diffs behind,
                    // except while a diff tab is up — then stay clear so its
                    // web view shows through from the stack below.
                    .background(paneLayerIsOpaque ? AnyShapeStyle(Color(nsColor: Theme.background)) : AnyShapeStyle(Color.clear))
                    .zIndex(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: Theme.background))

            RightSidebarView(manager: manager)
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            TerminalParkingView(sessions: parkedTerminalSessions)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if manager.isCommandPaletteVisible {
                CommandPaletteView(manager: manager)
            }
        }
        .background(WindowChromeAccessor())
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
    }

    /// Sessions in the visible tab are owned by `TerminalHostView`; every
    /// other session stays window-attached in the invisible parking host.
    private var parkedTerminalSessions: [TerminalSession] {
        let visibleIDs = Set(
            manager.selectedProject?.selectedTab?.sessions.map(\.id) ?? []
        )
        return manager.projects
            .flatMap(\.sessions)
            .filter { !visibleIDs.contains($0.id) }
    }

    /// The pane layer paints an opaque background to hide unselected diffs in
    /// its gaps — but a diff tab's own pane must stay clear so its web view
    /// (mounted in the stack behind) shows through.
    private var paneLayerIsOpaque: Bool {
        guard let tab = manager.selectedProject?.selectedTab else { return true }
        return tab.diffs.isEmpty
    }

    @ViewBuilder
    private var emptyState: some View {
        if manager.selectedProject == nil {
            emptyStatePrompt(
                title: "No open projects",
                buttonTitle: "New Project  ⌘N",
                action: { manager.newProject() }
            )
        } else {
            // A project whose tabs were all closed stays open; offer to reopen
            // a session rather than showing the no-projects prompt.
            emptyStatePrompt(
                title: "No open sessions",
                buttonTitle: "New Session  ⌘T",
                action: { manager.newSession() }
            )
        }
    }

    private func emptyStatePrompt(
        title: String, buttonTitle: String, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
        }
    }
}
