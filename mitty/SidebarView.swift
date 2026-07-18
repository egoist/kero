//
//  SidebarView.swift
//  mitty
//

import SwiftUI

/// Vertical tab strip listing terminal sessions, otty-style.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header-height strip housing the traffic-light buttons.
            Spacer()
                .frame(height: 38)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(manager.sessions.enumerated()), id: \.element.id) { index, session in
                        SidebarTabRow(
                            session: session,
                            index: index,
                            isSelected: session.id == manager.selectedID,
                            select: { manager.selectedID = session.id },
                            close: { manager.close(session) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Spacer(minLength: 8)

            Button {
                manager.newSession()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New Session")
                        .font(.system(size: 12))
                    Spacer()
                    Text("⌘T")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: 220)
        .background(VisualEffectView(material: .sidebar))
    }
}

private struct SidebarTabRow: View {
    @ObservedObject var session: TerminalSession
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color(nsColor: Theme.cursor) : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    if let dir = session.directoryLabel {
                        Text(dir)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isHovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
