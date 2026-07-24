#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    @Suite(.serialized)
    struct TerminalPasteboardTests {
        @Test
        func `copied files become shell-safe absolute paths`() {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }

            let plain = URL(fileURLWithPath: "/tmp/plain.png")
            let spaced = URL(fileURLWithPath: "/tmp/image with space.png")
            let quoted = URL(fileURLWithPath: "/tmp/user's image.png")
            #expect(pasteboard.writeObjects([
                plain as NSURL,
                spaced as NSURL,
                quoted as NSURL,
            ]))

            #expect(
                TerminalPasteboard.string(from: pasteboard)
                    == "/tmp/plain.png '/tmp/image with space.png' '/tmp/user'\\''s image.png'"
            )
        }

        @Test
        func `ordinary text remains ordinary text`() {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            #expect(pasteboard.setString("hello\nworld", forType: .string))

            #expect(TerminalPasteboard.string(from: pasteboard) == "hello\nworld")
            #expect(!TerminalPasteboard.containsImage(pasteboard))
        }

        @Test
        func `raw images are detected without converting them to text`() throws {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()

            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )
            let image = try #require(representation)
            let data = try #require(image.representation(using: .png, properties: [:]))
            #expect(pasteboard.setData(data, forType: .png))

            #expect(TerminalPasteboard.string(from: pasteboard) == nil)
            #expect(TerminalPasteboard.containsImage(pasteboard))
        }
    }
#endif
