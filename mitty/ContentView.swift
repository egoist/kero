//
//  ContentView.swift
//  mitty
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(manager: manager)

            VStack(spacing: 0) {
                MainHeaderView(manager: manager, session: manager.selectedSession)

                Group {
                    if let session = manager.selectedSession {
                        TerminalHostView(session: session)
                            .id(session.id)
                            .padding(.leading, 12)
                            .padding(.trailing, 6)
                            .padding(.top, 6)
                            .padding(.bottom, 10)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: Theme.background))

            RightSidebarView(manager: manager)
        }
        .ignoresSafeArea()
        .background(WindowChromeAccessor())
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No open sessions")
                .foregroundStyle(.secondary)
            Button("New Session  ⌘T") {
                manager.newSession()
            }
        }
    }
}

/// Slim bar above the terminal: session title on the left, sidebar
/// toggle on the right. Doubles as window-drag space.
private struct MainHeaderView: View {
    @ObservedObject var manager: TerminalManager
    let session: TerminalSession?

    var body: some View {
        HStack(spacing: 8) {
            if let session {
                SessionTitleView(session: session)
            }
            Spacer(minLength: 0)
            Button {
                manager.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(manager.isPanelVisible ? Color(nsColor: Theme.cursor) : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar (⇧⌘B)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }
}

private struct SessionTitleView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 6) {
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let dir = session.directoryLabel {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
                Text(dir)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
