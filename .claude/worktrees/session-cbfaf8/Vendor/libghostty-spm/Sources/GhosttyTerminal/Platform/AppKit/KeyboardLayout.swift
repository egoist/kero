#if canImport(AppKit) && !canImport(UIKit)
    import Carbon.HIToolbox

    enum KeyboardLayout {
        static var id: String? {
            guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            else {
                return nil
            }

            guard let rawProperty = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyInputSourceID
            ) else {
                return nil
            }

            let property = unsafeBitCast(rawProperty, to: CFString.self)
            return property as String
        }
    }
#endif
