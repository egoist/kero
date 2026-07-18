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
                MainHeaderView(manager: manager)

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
            Text("No open projects")
                .foregroundStyle(.secondary)
            Button("New Project  ⌘N") {
                manager.newProject()
            }
        }
    }
}

/// Slim bar above the terminal: the selected project's sessions as
/// horizontal tabs on the left, sidebar toggle on the right. Doubles as
/// window-drag space.
private struct MainHeaderView: View {
    @ObservedObject var manager: TerminalManager

    var body: some View {
        HStack(spacing: 8) {
            if let project = manager.selectedProject {
                SessionTabsView(project: project)
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
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }
}

/// Horizontal tabs for the sessions of one project, plus a "+" button.
private struct SessionTabsView: View {
    @ObservedObject var project: Project

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(project.sessions) { session in
                        SessionTabItem(
                            session: session,
                            isSelected: session.id == project.selectedSessionID,
                            select: { project.selectedSessionID = session.id },
                            close: { project.close(session) }
                        )
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)

            Button {
                project.newSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("New Session (⌘T)")
        }
    }
}

private struct SessionTabItem: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.cursor)) : AnyShapeStyle(.tertiary))
                Text(session.title)
                    .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                if isHovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 14)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
    }
}
