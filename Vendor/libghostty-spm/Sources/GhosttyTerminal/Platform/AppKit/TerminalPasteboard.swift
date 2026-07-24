//
//  TerminalPasteboard.swift
//  libghostty-spm
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    enum TerminalPasteboard {
        /// Mirrors Ghostty's macOS pasteboard preference: copied Finder
        /// items are pasted as shell-safe absolute paths before falling back
        /// to ordinary text.
        static func string(from pasteboard: NSPasteboard) -> String? {
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty {
                return urls
                    .map { shellToken(for: $0.path) }
                    .joined(separator: " ")
            }

            return pasteboard.string(forType: .string)
        }

        static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        }

        private static func shellToken(for path: String) -> String {
            let safe = Set(
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/"
            )
            if !path.isEmpty, path.allSatisfy({ safe.contains($0) }) {
                return path
            }
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
#endif
