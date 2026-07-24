@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalNavigationAPITests {
    @Test
    func `view state navigation requires an attached surface`() {
        let state = TerminalViewState()

        #expect(!state.performBindingAction("scroll_to_top"))
        #expect(!state.jumpToPrompt(by: -1))
        #expect(!state.scrollToRow(0))
    }

    @Test
    func `platform view exposes navigation actions`() {
        let invokeActions: (TerminalView) -> Void = { view in
            _ = view.performBindingAction("scroll_to_top")
            _ = view.jumpToPrompt(by: 1)
            _ = view.scrollToRow(42)
        }

        _ = invokeActions
    }
}
