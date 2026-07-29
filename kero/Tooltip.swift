//
//  Tooltip.swift
//  kero
//

import SwiftUI

/// Which side of the anchor view the label hangs off. Controls near the top
/// of a panel use `.below` so the label doesn't run off the window edge.
enum TooltipEdge {
    case above
    case below
}

extension View {
    /// A styled stand-in for `.help()`: same hover-to-reveal behavior, but
    /// themed with the app's materials and quicker than the system's delay.
    ///
    /// Pick the `edge` and `alignment` that keep the label growing *inward*
    /// from whatever panel edge the control sits against — the label is free
    /// to overhang its container, so a trailing button anchored `.leading`
    /// would spill outside the window.
    func tooltip(
        _ text: LocalizedStringKey,
        edge: TooltipEdge = .above,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        modifier(TooltipModifier(text: text, edge: edge, alignment: alignment))
    }
}

private struct TooltipModifier: ViewModifier {
    let text: LocalizedStringKey
    let edge: TooltipEdge
    let alignment: HorizontalAlignment

    @State private var isVisible = false
    @State private var revealTask: Task<Void, Never>?

    /// Label height (11pt text plus its padding) and the gap to the control.
    private static let offset: CGFloat = 25

    private var overlayAlignment: Alignment {
        Alignment(horizontal: alignment, vertical: edge == .above ? .top : .bottom)
    }

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                // Cancel first so a quick sweep across a row of controls
                // never leaves a label to flash in behind the pointer.
                revealTask?.cancel()
                guard hovering else {
                    isVisible = false
                    return
                }
                revealTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.1)) { isVisible = true }
                }
            }
            .onDisappear {
                revealTask?.cancel()
                isVisible = false
            }
            .overlay(alignment: overlayAlignment) {
                if isVisible {
                    label
                        .offset(y: edge == .above ? -Self.offset : Self.offset)
                        .transition(.opacity)
                }
            }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .allowsHitTesting(false)
    }
}
