import Darwin
import Darwin.ncurses
import Foundation

private let notificationName = Notification.Name("sh.kero.cli")

private struct CLITheme: Codable {
    let name: String
    let appearance: String
    let background: String
    let foreground: String
}

private struct ThemeState: Codable {
    let version: Int
    let appearance: String
    let selectedDark: String
    let selectedLight: String
    let themes: [CLITheme]
}

private enum Appearance: String {
    case dark
    case light

    var title: String {
        switch self {
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        }
    }

    var other: Appearance {
        switch self {
        case .dark: return .light
        case .light: return .dark
        }
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

private var cursesActiveAtExit = false

private func restoreTerminalAtExit() {
    guard cursesActiveAtExit else { return }
    _ = curs_set(1)
    _ = endwin()
    cursesActiveAtExit = false
}

private func installExitHandlers() {
    atexit(restoreTerminalAtExit)
    signal(SIGTERM) { signal in
        exit(128 + signal)
    }
    signal(SIGHUP) { signal in
        exit(128 + signal)
    }
    signal(SIGQUIT) { signal in
        exit(128 + signal)
    }
}

private final class AppConnection {
    let stateURL: URL
    let token: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let statePath = environment["KERO_CLI_STATE"],
              let token = environment["KERO_CLI_TOKEN"],
              !statePath.isEmpty,
              !token.isEmpty
        else {
            throw CLIError.message(
                String(localized: "`kero` must be run inside a Kero terminal.")
            )
        }
        stateURL = URL(fileURLWithPath: statePath)
        self.token = token
    }

    func loadState() throws -> ThemeState {
        let oldDate = try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        post(action: "refresh")

        // The app rewrites atomically. A short bounded wait keeps the default
        // light/dark slot accurate after a system appearance change while
        // still allowing a useful error when the owning app is unavailable.
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.02)
            let newDate = try? stateURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if oldDate == nil || newDate != oldDate { break }
        }

        do {
            let data = try Data(contentsOf: stateURL)
            let state = try JSONDecoder().decode(ThemeState.self, from: data)
            guard state.version == 1 else {
                throw CLIError.message(
                    String(localized: "This kero CLI does not understand theme catalog version \(state.version).")
                )
            }
            return state
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.message(
                String(localized: "Could not read Kero's theme catalog: \(error.localizedDescription)")
            )
        }
    }

    func post(
        action: String,
        id: String? = nil,
        appearance: Appearance? = nil,
        theme: String? = nil
    ) {
        var info: [String: Any] = [
            "token": token,
            "action": action,
        ]
        if let id {
            info["id"] = id
            info["pid"] = NSNumber(value: getpid())
        }
        if let appearance {
            info["appearance"] = appearance.rawValue
        }
        if let theme {
            info["theme"] = theme
        }
        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: nil,
            userInfo: info
        )
    }

    func createProject(arguments: [String]) {
        let environment = ProcessInfo.processInfo.environment
        let info: [String: Any] = [
            "token": token,
            "action": "openProject",
            "arguments": arguments,
            "directory": FileManager.default.currentDirectoryPath,
            "path": environment["PATH"] ?? "",
        ]
        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: nil,
            userInfo: info
        )
        // Let the app's main run loop claim the request before this short-lived
        // process disappears from the invoking terminal.
        Thread.sleep(forTimeInterval: 0.05)
    }
}

private final class ThemeBrowser {
    private let connection: AppConnection
    private let state: ThemeState
    private let invocationID = UUID().uuidString
    private var appearance: Appearance
    private var selectedNames: [Appearance: String]
    private var query = ""
    private var didPreview = false
    private var didSave = false

    init(
        connection: AppConnection,
        state: ThemeState,
        initialAppearance: Appearance?
    ) {
        self.connection = connection
        self.state = state
        appearance = initialAppearance ?? Appearance(rawValue: state.appearance) ?? .dark
        selectedNames = [
            .dark: state.selectedDark,
            .light: state.selectedLight,
        ]
    }

    func run() throws -> (theme: String, appearance: Appearance)? {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw CLIError.message(
                String(localized: "`kero +themes` needs an interactive terminal. Use `kero +themes --list` to print theme names.")
            )
        }
        guard !themes(for: appearance).isEmpty else {
            throw CLIError.message(String(localized: "Kero did not provide any \(appearance.title) themes."))
        }

        try enterTerminalUI()
        defer {
            leaveTerminalUI()
            if didPreview && !didSave {
                connection.post(action: "cancel", id: invocationID)
            }
        }

        normalizeSelection()
        previewSelection()
        draw()

        while true {
            switch readKey() {
            case .up:
                moveSelection(by: -1)
            case .down:
                moveSelection(by: 1)
            case .pageUp:
                moveSelection(by: -max(1, listHeight() - 1))
            case .pageDown:
                moveSelection(by: max(1, listHeight() - 1))
            case .tab:
                appearance = appearance.other
                query = ""
                normalizeSelection()
                previewSelection()
            case .backspace:
                if !query.isEmpty {
                    query.removeLast()
                    normalizeSelection()
                    previewSelection()
                }
            case .clearQuery:
                if !query.isEmpty {
                    query = ""
                    normalizeSelection()
                    previewSelection()
                }
            case .character(let character):
                query.append(character)
                normalizeSelection()
                previewSelection()
            case .enter:
                guard let theme = selectedTheme else { continue }
                connection.post(
                    action: "save",
                    id: invocationID,
                    appearance: appearance,
                    theme: theme.name
                )
                didSave = true
                // Keep this process alive long enough for the main run loop to
                // receive the final distributed notification before PID
                // monitoring observes an exit.
                Thread.sleep(forTimeInterval: 0.05)
                return (theme.name, appearance)
            case .cancel:
                return nil
            case .none:
                continue
            }
            draw()
        }
    }

    private var filteredThemes: [CLITheme] {
        let candidates = themes(for: appearance)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            Self.fuzzyMatch(query.lowercased(), in: $0.name.lowercased())
        }
    }

    private var selectedTheme: CLITheme? {
        guard let name = selectedNames[appearance] else { return nil }
        return filteredThemes.first { $0.name == name }
    }

    private func themes(for appearance: Appearance) -> [CLITheme] {
        state.themes.filter { $0.appearance == appearance.rawValue }
    }

    private func normalizeSelection() {
        let filtered = filteredThemes
        guard !filtered.isEmpty else { return }
        if selectedTheme == nil {
            selectedNames[appearance] = filtered[0].name
        }
    }

    private func moveSelection(by offset: Int) {
        let filtered = filteredThemes
        guard !filtered.isEmpty else { return }
        let current = filtered.firstIndex { $0.name == selectedNames[appearance] } ?? 0
        let next = min(max(current + offset, 0), filtered.count - 1)
        guard filtered[next].name != selectedNames[appearance] else { return }
        selectedNames[appearance] = filtered[next].name
        previewSelection()
    }

    private func previewSelection() {
        guard let theme = selectedTheme else { return }
        connection.post(
            action: "preview",
            id: invocationID,
            appearance: appearance,
            theme: theme.name
        )
        didPreview = true
    }

    private func draw() {
        let width = terminalSize().columns
        let height = listHeight()
        let filtered = filteredThemes
        let selectedIndex = filtered.firstIndex {
            $0.name == selectedNames[appearance]
        }
        let start: Int
        if let selectedIndex {
            start = min(
                max(0, selectedIndex - height / 2),
                max(0, filtered.count - height)
            )
        } else {
            start = 0
        }
        let visible = filtered.dropFirst(start).prefix(height)

        var output = "\u{1B}[2J\u{1B}[H"
        output += "  \u{1B}[1mKero +themes\u{1B}[0m"
        output += "  \u{1B}[2m"
            + String(localized: "\(appearance.title) palette · Tab switches appearance")
            + "\u{1B}[0m\r\n"
        output += "  \u{1B}[2m" + String(localized: "Type to filter:") + " \u{1B}[0m"
        output += query.isEmpty
            ? "\u{1B}[2m" + String(localized: "(all themes)") + "\u{1B}[0m"
            : query
        output += "\r\n\r\n"

        if visible.isEmpty {
            output += "  \u{1B}[2m"
                + String(localized: "No themes match “\(query)”.")
                + "\u{1B}[0m\r\n"
        } else {
            for (offset, theme) in visible.enumerated() {
                let index = start + offset
                let selected = index == selectedIndex
                let marker = selected ? "\u{1B}[1m›\u{1B}[0m" : " "
                let swatch = Self.swatch(theme)
                let reserved = 10
                let availableNameWidth = max(8, width - reserved)
                let name = String(theme.name.prefix(availableNameWidth))
                let style = selected ? "\u{1B}[1m" : ""
                output += " \(marker) \(swatch) \(style)\(name)\u{1B}[0m\r\n"
            }
        }

        let padding = max(0, height - max(1, visible.count))
        if padding > 0 {
            output += String(repeating: "\r\n", count: padding)
        }
        output += "\r\n  \u{1B}[2m"
            + String(localized: "↑↓ navigate · Return save · Esc cancel · Tab light/dark")
            + "\u{1B}[0m"
        writeOutput(output)
    }

    private func enterTerminalUI() throws {
        guard initscr() != nil else {
            throw CLIError.message(String(localized: "Could not initialize the interactive terminal."))
        }
        cursesActiveAtExit = true

        guard raw() != ERR,
              noecho() != ERR,
              keypad(stdscr, true) == OK
        else {
            restoreTerminalAtExit()
            throw CLIError.message(String(localized: "Could not enter interactive terminal mode."))
        }

        // ncurses owns terminal modes, escape-sequence decoding, and alternate
        // screen restoration. Kero still draws with ANSI because this browser
        // only needs structured keyboard input, not a full widget framework.
        _ = set_escdelay(25)
        _ = curs_set(0)
        _ = wrefresh(stdscr)
        _ = untouchwin(stdscr)
    }

    private func leaveTerminalUI() {
        restoreTerminalAtExit()
    }

    private enum Key {
        case up
        case down
        case pageUp
        case pageDown
        case tab
        case backspace
        case clearQuery
        case character(Character)
        case enter
        case cancel
        case none
    }

    private func readKey() -> Key {
        let code = wgetch(stdscr)
        switch code {
        case ERR:
            return .cancel
        case KEY_UP:
            return .up
        case KEY_DOWN:
            return .down
        case KEY_PPAGE:
            return .pageUp
        case KEY_NPAGE:
            return .pageDown
        case KEY_ENTER:
            return .enter
        case KEY_BACKSPACE:
            return .backspace
        case 3, 4, 17:
            return .cancel
        case 9:
            return .tab
        case 10, 13:
            return .enter
        case 21:
            return .clearQuery
        case 8, 127:
            return .backspace
        case 14:
            return .down
        case 16:
            return .up
        case 27:
            // keypad() has already translated recognized escape sequences.
            // If another decoded value remains, this was an Option/Alt chord
            // or an unknown sequence rather than a standalone Escape.
            wtimeout(stdscr, 0)
            let continuation = wgetch(stdscr)
            wtimeout(stdscr, -1)
            guard continuation == ERR else {
                _ = flushinp()
                return .none
            }
            return .cancel
        case 32...126:
            return .character(Character(UnicodeScalar(UInt8(code))))
        default:
            return .none
        }
    }

    private func listHeight() -> Int {
        max(3, terminalSize().rows - 7)
    }

    private func terminalSize() -> (columns: Int, rows: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else {
            return (80, 24)
        }
        return (
            max(20, Int(size.ws_col)),
            max(10, Int(size.ws_row))
        )
    }

    private static func fuzzyMatch(_ query: String, in candidate: String) -> Bool {
        var queryIndex = query.startIndex
        for character in candidate {
            guard queryIndex != query.endIndex else { return true }
            if character == query[queryIndex] {
                query.formIndex(after: &queryIndex)
            }
        }
        return queryIndex == query.endIndex
    }

    private static func swatch(_ theme: CLITheme) -> String {
        guard let background = rgb(theme.background),
              let foreground = rgb(theme.foreground)
        else { return " Aa " }
        return "\u{1B}[48;2;\(background.r);\(background.g);\(background.b)m"
            + "\u{1B}[38;2;\(foreground.r);\(foreground.g);\(foreground.b)m"
            + " Aa \u{1B}[0m"
    }

    private static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return nil
        }
        return (
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff
        )
    }
}

private func writeOutput(_ string: String) {
    FileHandle.standardOutput.write(Data(string.utf8))
}

private func printHelp() {
    print(
        String(localized: """
        Usage:
          kero
          kero <command> [arguments...]
          kero +themes [--dark | --light]
          kero +themes --list [--dark | --light]
          kero +help

        With no arguments, kero creates a project with a normal login shell.
        An argv creates a project whose first terminal runs it directly.

        +themes browses Kero's themes in the terminal. Moving through the list
        previews the theme across the whole app; Return saves it and Esc
        restores the previous theme.
        """)
    )
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["+help"] {
        printHelp()
        return
    }
    if arguments.first != "+themes" {
        if let command = arguments.first, command.hasPrefix("+") {
            throw CLIError.message(
                String(localized: "Unknown Kero command “\(command)”. Run `kero +help`.")
            )
        }
        let connection = try AppConnection()
        connection.createProject(arguments: arguments)
        return
    }

    var requestedAppearance: Appearance?
    var listOnly = false
    for argument in arguments.dropFirst() {
        switch argument {
        case "--dark":
            guard requestedAppearance != .light else {
                throw CLIError.message(String(localized: "Choose only one of --dark and --light."))
            }
            requestedAppearance = .dark
        case "--light":
            guard requestedAppearance != .dark else {
                throw CLIError.message(String(localized: "Choose only one of --dark and --light."))
            }
            requestedAppearance = .light
        case "--list":
            listOnly = true
        case "--help", "-h":
            printHelp()
            return
        default:
            throw CLIError.message(
                String(localized: "Unknown option “\(argument)”. Run `kero +themes --help`.")
            )
        }
    }

    let connection = try AppConnection()
    let state = try connection.loadState()
    let appearance = requestedAppearance
        ?? Appearance(rawValue: state.appearance)
        ?? .dark

    if listOnly {
        for theme in state.themes where theme.appearance == appearance.rawValue {
            print(theme.name)
        }
        return
    }

    let browser = ThemeBrowser(
        connection: connection,
        state: state,
        initialAppearance: requestedAppearance
    )
    if let saved = try browser.run() {
        print(String(localized: "Saved \(saved.theme) as Kero's \(saved.appearance.title) theme."))
    }
}

enum KeroCommandLine {
    /// The per-process bridge variables identify invocations from a Kero
    /// terminal. A `+` action is also CLI-shaped so `kero +help` works when the
    /// executable is called directly. Other arguments may belong to AppKit or
    /// Xcode and must continue through the normal application entry point.
    static var shouldRun: Bool {
        let environment = ProcessInfo.processInfo.environment
        let hasBridge = environment["KERO_CLI_STATE"]?.isEmpty == false
            && environment["KERO_CLI_TOKEN"]?.isEmpty == false
        if hasBridge { return true }
        return CommandLine.arguments.dropFirst().first?.hasPrefix("+") == true
    }

    static func main() -> Never {
        installExitHandlers()

        do {
            try run()
            exit(0)
        } catch {
            fputs("kero: \(error)\n", stderr)
            exit(1)
        }
    }
}
