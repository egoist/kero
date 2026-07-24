//
//  TerminalFindBar.swift
//  kero
//

import AppKit
import SwiftUI

/// Compact find bar floating over a terminal pane's top-right corner. Ghostty
/// draws the match highlights inside the grid itself, so this only carries the
/// field, the tally, and the navigation controls.
struct TerminalFindBar: View {
    @ObservedObject var find: TerminalFind

    @FocusState private var fieldFocused: Bool

    private var hasMatches: Bool { (find.total ?? 0) > 0 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Find", text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($fieldFocused)
                .onKeyPress(.escape) {
                    find.dismiss()
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    find.navigate(forward: !press.modifiers.contains(.shift))
                    return .handled
                }

            Text(counterText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(find.total == 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                // Fixed width so typing doesn't shuffle the controls sideways
                // as the tally grows and shrinks.
                .frame(width: 52, alignment: .trailing)

            navigationButton("chevron.up", forward: false)
            navigationButton("chevron.down", forward: true)

            Button {
                find.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Close find bar")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: Theme.background))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .padding(.top, 10)
        .padding(.trailing, 16)
        // Same deferral the command palette needs: focus assigned inside the
        // appearance pass is dropped before the field editor exists.
        .onAppear { focusField() }
        .onChange(of: find.focusRequest) { focusField() }
        // Hand keyboard focus back only once this bar has actually left the
        // view tree, so AppKit cannot resign the field editor afterwards and
        // undo it.
        .onDisappear { find.restoreTerminalFocus() }
    }

    private func navigationButton(_ symbol: String, forward: Bool) -> some View {
        Button {
            find.navigate(forward: forward)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hasMatches ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!hasMatches)
        .help(forward ? "Next match" : "Previous match")
    }

    /// Blank while a count for the current needle is still pending, so a tally
    /// belonging to the previous term is never shown.
    private var counterText: String {
        guard !find.query.isEmpty, let total = find.total else { return "" }
        guard total > 0 else { return "0/0" }
        guard let selected = find.selected else { return "\(total)" }
        return "\(min(selected + 1, total))/\(total)"
    }

    private func focusField() {
        DispatchQueue.main.async {
            fieldFocused = true
            selectQuery()
        }
    }

    /// Selects the whole term, so reopening the bar over an existing needle
    /// lets you type straight over it.
    private func selectQuery() {
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}
