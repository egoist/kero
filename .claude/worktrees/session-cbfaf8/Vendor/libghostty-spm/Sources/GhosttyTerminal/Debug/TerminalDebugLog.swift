import Foundation
import GhosttyKit

public struct TerminalDebugCategory: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let lifecycle = Self(rawValue: 1 << 0)
    public static let metrics = Self(rawValue: 1 << 1)
    public static let input = Self(rawValue: 1 << 2)
    public static let output = Self(rawValue: 1 << 3)
    public static let ime = Self(rawValue: 1 << 4)
    public static let actions = Self(rawValue: 1 << 5)
    public static let render = Self(rawValue: 1 << 6)

    public static let standard: Self = [
        .lifecycle,
        .metrics,
        .input,
        .output,
        .ime,
        .actions,
    ]

    public static let all: Self = [
        .standard,
        .render,
    ]
}

public enum TerminalDebugLog {
    public typealias Sink = @Sendable (String) -> Void

    private struct Snapshot {
        let isEnabled: Bool
        let categories: TerminalDebugCategory
        let sink: Sink
    }

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var isEnabled = false
        var categories: TerminalDebugCategory = .standard
        var sink: Sink = { message in
            Swift.print(message)
        }
    }

    private static let store = Store()

    public static var isEnabled: Bool {
        get {
            withSnapshot { $0.isEnabled }
        }
        set {
            updateStore { $0.isEnabled = newValue }
        }
    }

    public static var categories: TerminalDebugCategory {
        get {
            withSnapshot { $0.categories }
        }
        set {
            updateStore { $0.categories = newValue }
        }
    }

    public static var sink: Sink {
        get {
            withSnapshot { $0.sink }
        }
        set {
            updateStore { $0.sink = newValue }
        }
    }

    public static func enable(_ categories: TerminalDebugCategory = .standard) {
        updateStore {
            $0.isEnabled = true
            $0.categories = categories
        }
    }

    public static func disable() {
        updateStore { $0.isEnabled = false }
    }

    static func log(
        _ category: TerminalDebugCategory,
        _ message: @autoclosure () -> String
    ) {
        let snapshot = snapshot()
        guard snapshot.isEnabled else { return }
        guard snapshot.categories.contains(category) else { return }
        snapshot.sink(
            "[GhosttyTerminal][\(timestamp())][\(label(for: category))] \(message())"
        )
    }

    static func describe(_ string: String?, limit: Int = 96) -> String {
        guard let string else { return "nil" }
        return "\"\(escaped(string, limit: limit))\""
    }

    static func describe(_ data: Data, limit: Int = 48) -> String {
        let preview = data.prefix(limit)
        let text = String(decoding: preview, as: UTF8.self)
        let hex = preview.map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = data.count > limit ? "..." : ""
        return "bytes=\(data.count) utf8=\"\(escaped(text, limit: limit))\(suffix)\" hex=\(hex)\(suffix)"
    }

    static func describe(_ range: NSRange) -> String {
        "{location=\(range.location), length=\(range.length)}"
    }

    static func describe(_ action: ghostty_input_action_e) -> String {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            "press"
        case GHOSTTY_ACTION_RELEASE:
            "release"
        case GHOSTTY_ACTION_REPEAT:
            "repeat"
        default:
            "unknown(\(action.rawValue))"
        }
    }

    static func describe(_ state: ghostty_input_mouse_state_e) -> String {
        switch state {
        case GHOSTTY_MOUSE_PRESS:
            "press"
        case GHOSTTY_MOUSE_RELEASE:
            "release"
        default:
            "unknown(\(state.rawValue))"
        }
    }

    static func describe(_ tag: ghostty_action_tag_e) -> String {
        switch tag {
        case GHOSTTY_ACTION_CELL_SIZE:
            "cell_size"
        case GHOSTTY_ACTION_SET_TITLE:
            "set_title"
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            "set_tab_title"
        case GHOSTTY_ACTION_RING_BELL:
            "ring_bell"
        case GHOSTTY_ACTION_RENDER:
            "render"
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            "config_change"
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            "reload_config"
        default:
            "tag(\(tag.rawValue))"
        }
    }

    private static func withSnapshot<T>(
        _ body: (Snapshot) -> T
    ) -> T {
        body(snapshot())
    }

    private static func snapshot() -> Snapshot {
        store.lock.lock()
        defer { store.lock.unlock() }
        return Snapshot(
            isEnabled: store.isEnabled,
            categories: store.categories,
            sink: store.sink
        )
    }

    private static func updateStore(
        _ body: (Store) -> Void
    ) {
        store.lock.lock()
        defer { store.lock.unlock() }
        body(store)
    }

    private static func label(
        for category: TerminalDebugCategory
    ) -> String {
        switch category {
        case .lifecycle:
            "lifecycle"
        case .metrics:
            "metrics"
        case .input:
            "input"
        case .output:
            "output"
        case .ime:
            "ime"
        case .actions:
            "actions"
        case .render:
            "render"
        default:
            "debug"
        }
    }

    private static func timestamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince1970)
    }

    private static func escaped(
        _ string: String,
        limit: Int
    ) -> String {
        var result = ""
        var emitted = 0
        for scalar in string.unicodeScalars {
            guard emitted < limit else {
                result.append("...")
                break
            }

            switch scalar.value {
            case 0x09:
                result.append("\\t")
            case 0x0A:
                result.append("\\n")
            case 0x0D:
                result.append("\\r")
            case 0x1B:
                result.append("\\e")
            case 0x20 ..< 0x7F:
                result.append(Character(scalar))
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result.append(String(format: "\\u{%02X}", Int(scalar.value)))
                } else {
                    result.append(Character(scalar))
                }
            }

            emitted += 1
        }
        return result
    }
}

extension TerminalGridMetrics {
    var debugSummary: String {
        "cols=\(columns) rows=\(rows) pixels=\(widthPixels)x\(heightPixels) cell=\(cellWidthPixels)x\(cellHeightPixels)"
    }
}

extension TerminalViewportMetrics {
    var debugSummary: String {
        "\(surfaceSize.debugSummary) scale=\(String(format: "%.2f", scale))"
    }
}

extension TerminalSessionBackend {
    var debugSummary: String {
        switch self {
        case .exec:
            "exec"
        case .inMemory:
            "in-memory"
        }
    }
}

extension TerminalSurfaceOptions {
    var debugSummary: String {
        let fontSizeDescription = fontSize.map { String($0) } ?? "nil"
        return "backend=\(backend.debugSummary) fontSize=\(fontSizeDescription) workingDirectory=\(workingDirectory ?? "nil") context=\(context.debugSummary)"
    }
}

extension TerminalSurfaceContext {
    var debugSummary: String {
        switch self {
        case .window:
            "window"
        case .split:
            "split"
        }
    }
}

extension TerminalHardwareKeyDelivery {
    var debugSummary: String {
        switch self {
        case let .ghostty(key):
            "ghostty(\(key.rawValue))"
        case let .data(data):
            "data(\(TerminalDebugLog.describe(data)))"
        }
    }
}
