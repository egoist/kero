//
//  TerminalTextPosition.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import UIKit

    final class TerminalTextPosition: UITextPosition {
        let index: Int

        init(_ index: Int) {
            self.index = index
            super.init()
        }
    }

    final class TerminalTextRange: UITextRange {
        private let _start: TerminalTextPosition
        private let _end: TerminalTextPosition

        override var start: UITextPosition {
            _start
        }

        override var end: UITextPosition {
            _end
        }

        override var isEmpty: Bool {
            _start.index >= _end.index
        }

        var startPosition: TerminalTextPosition {
            _start
        }

        var endPosition: TerminalTextPosition {
            _end
        }

        var location: Int {
            _start.index
        }

        var length: Int {
            _end.index - _start.index
        }

        init(start: TerminalTextPosition, end: TerminalTextPosition) {
            _start = start
            _end = end
            super.init()
        }

        convenience init(location: Int, length: Int) {
            self.init(
                start: TerminalTextPosition(location),
                end: TerminalTextPosition(location + length)
            )
        }
    }
#endif
