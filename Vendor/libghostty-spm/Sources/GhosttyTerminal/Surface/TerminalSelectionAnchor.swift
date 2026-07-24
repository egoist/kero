//
//  TerminalSelectionAnchor.swift
//  libghostty-spm
//

import Foundation

enum TerminalSelectionAnchor {
    /// Map a quicklook word + its top-left host-point coordinate back into
    /// an `NSRange` inside the viewport text snapshot, suitable for direct
    /// assignment to `UITextView.selectedRange`.
    ///
    /// Strategy: derive `row` from `pointY / cellHeightPoints`; collect every
    /// literal occurrence of `word` in that row; then use
    /// `pointX / cellWidthPoints` as the expected UTF-16 column and pick the
    /// match whose `location` is closest. This resolves substring ambiguity
    /// (e.g. `catalog cat` long-pressed at the end picks the standalone
    /// `cat`, not the prefix of `catalog`) without depending on word
    /// boundaries — which would fail for tokens like `/foo` whose first
    /// character is a non-word character.
    ///
    /// Units: `pointX/Y` and `cellWidth/HeightPoints` must all be host
    /// points (not surface pixels). Callers are responsible for converting
    /// `cellPixels / displayScale → points` before invoking. Ghostty's
    /// embedded API returns `tl_px_x/y` in host points, so passing them
    /// through unchanged is correct.
    ///
    /// Known limitation: when the target row contains CJK full-width
    /// characters before the match, cell columns and UTF-16 offsets diverge
    /// (CJK = 2 cells, 1 UTF-16 unit), so disambiguation between duplicates
    /// may pick the wrong occurrence. ASCII-only scenarios are exact.
    static func resolveRange(
        in text: String,
        word: String,
        pointX: Double,
        pointY: Double,
        cellWidthPoints: Double,
        cellHeightPoints: Double
    ) -> NSRange? {
        guard !word.isEmpty else { return nil }
        guard pointX.isFinite, pointY.isFinite,
              cellWidthPoints.isFinite, cellHeightPoints.isFinite
        else { return nil }
        guard cellWidthPoints > 0, cellHeightPoints > 0 else { return nil }
        guard pointX >= 0, pointY >= 0 else { return nil }

        let rowDouble = pointY / cellHeightPoints
        let columnDouble = pointX / cellWidthPoints
        guard rowDouble.isFinite, columnDouble.isFinite,
              rowDouble < Double(Int.max), columnDouble < Double(Int.max)
        else { return nil }

        let row = Int(rowDouble)
        let expectedColumnUTF16 = Int(columnDouble)

        let nsText = text as NSString
        let lines = nsText.components(separatedBy: "\n")
        guard row >= 0, row < lines.count else { return nil }

        let line = lines[row] as NSString
        let wordNS = word as NSString

        var matches: [NSRange] = []
        var searchLocation = 0
        while searchLocation < line.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: line.length - searchLocation
            )
            let hit = line.range(of: word, options: .literal, range: searchRange)
            if hit.location == NSNotFound { break }
            matches.append(hit)
            searchLocation = NSMaxRange(hit)
            if wordNS.length == 0 { break }
        }
        guard !matches.isEmpty else { return nil }

        let chosen = matches.min { lhs, rhs in
            abs(lhs.location - expectedColumnUTF16) < abs(rhs.location - expectedColumnUTF16)
        }!

        var offset = 0
        for i in 0 ..< row {
            offset += (lines[i] as NSString).length + 1 // +1 for "\n"
        }

        let result = NSRange(location: offset + chosen.location, length: chosen.length)
        guard NSMaxRange(result) <= nsText.length else { return nil }
        return result
    }
}
