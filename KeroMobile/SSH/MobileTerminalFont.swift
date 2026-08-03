import CoreText
import UIKit

@MainActor
enum MobileTerminalFont {
    static let regularPostScriptName = "JetBrainsMono-Regular"

    private static var registrationResult: Bool?
    private static let bundledFaces = [
        "JetBrainsMono-Regular",
        "JetBrainsMono-Bold",
        "JetBrainsMono-Italic",
        "JetBrainsMono-BoldItalic",
    ]

    @discardableResult
    static func registerBundledFonts() -> Bool {
        if let registrationResult {
            return registrationResult
        }
        let urls = bundledFaces.compactMap {
            Bundle.main.url(forResource: $0, withExtension: "ttf")
        }
        guard urls.count == bundledFaces.count else {
            registrationResult = false
            return false
        }
        CTFontManagerRegisterFontURLs(
            urls as CFArray,
            .process,
            true,
            nil
        )
        let succeeded = UIFont(name: regularPostScriptName, size: 14) != nil
        registrationResult = succeeded
        return succeeded
    }

    static func regular(ofSize size: CGFloat) -> UIFont {
        registerBundledFonts()
        return UIFont(name: regularPostScriptName, size: size)
            ?? UIFont.monospacedSystemFont(
                ofSize: size,
                weight: .regular
            )
    }
}
