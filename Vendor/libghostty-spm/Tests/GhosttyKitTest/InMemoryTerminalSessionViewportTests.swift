@testable import GhosttyTerminal
import Testing

@MainActor
struct InMemoryTerminalSessionViewportTests {
    /// `readViewportText()` MUST return `nil` (not crash) when no surface is
    /// attached. This is the canonical pre-surface / post-surface-teardown
    /// state — consumers may call `readViewportText` from any thread that
    /// holds a reference, and the contract is "nil means no surface."
    @Test
    func `read viewport text returns nil before surface attached`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        #expect(session.readViewportText() == nil)
    }

    /// After clearing the surface, the read MUST go back to returning `nil`.
    /// Together with the test above this pins the surface-presence semantics
    /// of the public API.
    @Test
    func `read viewport text returns nil after surface cleared`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        session.clearSurface(ifMatches: nil)
        #expect(session.readViewportText() == nil)
    }
}
