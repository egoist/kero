@testable import GhosttyTerminal
import SwiftUI
import Testing

@Suite("TerminalSurfaceViewFocusAPI")
struct TerminalSurfaceViewFocusAPITests {
    @Test
    @MainActor
    func `bool focus modifier compiles`() {
        _ = BoolFocusSmokeView()
    }

    @Test
    @MainActor
    func `optional focus modifier compiles`() {
        _ = OptionalFocusSmokeView()
    }
}

@available(macOS 13.0, iOS 15.0, macCatalyst 15.0, *)
private struct BoolFocusSmokeView: View {
    @StateObject private var state = TerminalViewState()
    @FocusState private var isFocused: Bool

    var body: some View {
        TerminalSurfaceView(context: state)
            .terminalFocused($isFocused)
    }
}

@available(macOS 13.0, iOS 15.0, macCatalyst 15.0, *)
private struct OptionalFocusSmokeView: View {
    enum Pane: Hashable {
        case primary
    }

    @StateObject private var state = TerminalViewState()
    @FocusState private var focusedPane: Pane?

    var body: some View {
        TerminalSurfaceView(context: state)
            .terminalFocusOnAppear($focusedPane, equals: .primary)
    }
}
