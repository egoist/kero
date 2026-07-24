import Foundation

/// Owns the platform-agnostic state for IME marked text so AppKit and UIKit
/// can share one editing model.
struct TerminalMarkedTextState {
    private(set) var text: String?
    private(set) var selectedRange = NSRange(location: 0, length: 0)

    var hasMarkedText: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }

    var documentLength: Int {
        text?.utf16.count ?? 0
    }

    var markedRange: NSRange {
        guard hasMarkedText else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: documentLength)
    }

    var currentSelectedRange: NSRange {
        guard hasMarkedText else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return selectedRange
    }

    mutating func setMarkedText(_ text: String?, selectedRange: NSRange) {
        let normalizedText = text.flatMap { $0.isEmpty ? nil : $0 }
        self.text = normalizedText
        self.selectedRange = clampedSelectedRange(selectedRange, in: normalizedText)
    }

    mutating func clear() {
        text = nil
        selectedRange = NSRange(location: 0, length: 0)
    }

    mutating func deleteBackward() -> Bool {
        guard let text, !text.isEmpty else { return false }

        let mutableText = NSMutableString(string: text)
        if selectedRange.length > 0 {
            mutableText.deleteCharacters(in: selectedRange)
            selectedRange = NSRange(location: selectedRange.location, length: 0)
        } else if selectedRange.location > 0 {
            let deletionRange = NSRange(location: selectedRange.location - 1, length: 1)
            mutableText.deleteCharacters(in: deletionRange)
            selectedRange = NSRange(location: deletionRange.location, length: 0)
        } else {
            return true
        }

        let updatedText = mutableText as String
        self.text = updatedText.isEmpty ? nil : updatedText
        if self.text == nil {
            selectedRange = NSRange(location: 0, length: 0)
        }
        return true
    }

    func text(in range: NSRange) -> String? {
        guard let text else {
            return range.length == 0 ? "" : nil
        }

        let nsText = text as NSString
        guard range.location >= 0, range.length >= 0 else { return nil }
        guard range.location + range.length <= nsText.length else { return nil }
        return nsText.substring(with: range)
    }

    private func clampedSelectedRange(
        _ range: NSRange,
        in text: String?
    ) -> NSRange {
        let length = text?.utf16.count ?? 0
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, location), length)
        return NSRange(location: location, length: end - location)
    }
}
