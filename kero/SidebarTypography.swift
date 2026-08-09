//
//  SidebarTypography.swift
//  kero
//

import SwiftUI

private struct SidebarFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var sidebarFontScale: CGFloat {
        get { self[SidebarFontScaleKey.self] }
        set { self[SidebarFontScaleKey.self] = newValue }
    }
}

/// Scales a sidebar font from its designed size while preserving the relative
/// hierarchy between section labels, content, metadata, and controls.
private struct SidebarFontModifier: ViewModifier {
    @Environment(\.sidebarFontScale) private var scale

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    func sidebarFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(SidebarFontModifier(size: size, weight: weight, design: design))
    }
}
