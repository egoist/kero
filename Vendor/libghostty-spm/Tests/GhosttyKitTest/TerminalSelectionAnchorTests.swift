import Foundation
@testable import GhosttyTerminal
import Testing

// All test cases use host-point units. cellWidthPoints = 10, cellHeightPoints = 20
// unless otherwise noted. The function's contract is "pointX / cellWidthPoints
// = expected cell column" — that identity holds regardless of physical device
// scale, so callers passing host points consistently get correct results on
// @1x/2x/3x devices alike. A caller passing surface pixels without dividing
// by displayScale would compute the wrong expectedColumn — that's a caller
// bug, not a function bug. See plan §1 and §10审 for the unit contract.

struct TerminalSelectionAnchorTests {
    @Test
    func `single line ASCII`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "hello world",
            word: "world",
            pointX: 60, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 6, length: 5))
    }

    @Test
    func `multi line locates row`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "aaa\nbbb\nworld",
            word: "world",
            pointX: 0, pointY: 40,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 8, length: 5))
    }

    @Test
    func `same word across rows only picks target row`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "foo\nfoo\nfoo",
            word: "foo",
            pointX: 0, pointY: 20,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 4, length: 3))
    }

    @Test
    func `empty rows preserved`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "\n\nhello",
            word: "hello",
            pointX: 0, pointY: 40,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 2, length: 5))
    }

    @Test
    func `word not found returns nil`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "abc",
            word: "xyz",
            pointX: 0, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == nil)
    }

    @Test
    func `row out of bounds returns nil`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "abc",
            word: "abc",
            pointX: 0, pointY: 100,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == nil)
    }

    @Test
    func `emoji surrogate pair`() {
        let text = "hi 👋"
        let range = TerminalSelectionAnchor.resolveRange(
            in: text,
            word: "👋",
            pointX: 30, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        let nsText = text as NSString
        #expect(range != nil)
        if let r = range {
            #expect(r == NSRange(location: 3, length: 2))
            #expect(NSMaxRange(r) <= nsText.length)
        }
    }

    @Test
    func `cjk full width`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "你好 world",
            word: "你好",
            pointX: 0, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 0, length: 2))
    }

    @Test
    func `zero cell dimensions`() {
        let r1 = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "abc",
            pointX: 0, pointY: 0,
            cellWidthPoints: 0, cellHeightPoints: 20
        )
        let r2 = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "abc",
            pointX: 0, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 0
        )
        #expect(r1 == nil)
        #expect(r2 == nil)
    }

    @Test
    func `empty word`() {
        let range = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "",
            pointX: 0, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == nil)
    }

    @Test
    func `negative coordinates`() {
        let r1 = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "abc",
            pointX: -1, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        let r2 = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "abc",
            pointX: 0, pointY: -1,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(r1 == nil)
        #expect(r2 == nil)
    }

    @Test
    func `substring disambiguation by point X`() {
        // `catalog cat` long-pressed at the end `cat` (column 8) — must pick
        // the standalone `cat` at location 8, not the prefix inside `catalog`
        // at location 0. literals at {0, 8}, expectedColumn=8 → 8.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "catalog cat",
            word: "cat",
            pointX: 80, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 8, length: 3))
    }

    @Test
    func `triple repeat picked by point X`() {
        // literals at {0, 4, 8}, expectedColumn=8 → 8.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "cat cat cat",
            word: "cat",
            pointX: 80, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 8, length: 3))
    }

    @Test
    func `non word characters in token`() {
        // literals at {4, 15}, expectedColumn=15 → 15.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "see /usr/local /usr/local",
            word: "/usr/local",
            pointX: 150, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 15, length: 10))
    }

    @Test
    func `non word prefix token`() {
        // literals at {1, 6}, expectedColumn=6 → 6.
        let range = TerminalSelectionAnchor.resolveRange(
            in: "x/foo /foo",
            word: "/foo",
            pointX: 60, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        #expect(range == NSRange(location: 6, length: 4))
    }

    @Test
    func `nan and infinity guarded`() {
        let r1 = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "abc",
            pointX: .nan, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        let r2 = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "abc",
            pointX: .infinity, pointY: 0,
            cellWidthPoints: 10, cellHeightPoints: 20
        )
        let r3 = TerminalSelectionAnchor.resolveRange(
            in: "abc", word: "abc",
            pointX: 0, pointY: 0,
            cellWidthPoints: .nan, cellHeightPoints: 20
        )
        #expect(r1 == nil)
        #expect(r2 == nil)
        #expect(r3 == nil)
    }
}
