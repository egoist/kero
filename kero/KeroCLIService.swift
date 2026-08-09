//
//  KeroCLIService.swift
//  kero
//

import AppKit
import Darwin
import Foundation
import GhosttyTheme

/// Bridges the bundled `kero` executable back to its owning app process.
///
/// Theme previews retain the original per-launch distributed-notification
/// bridge. Terminal and agent automation use a separate private Unix socket
/// plus a per-terminal capability, because the broader theme token was never
/// designed to authorize pane reads or input.
@MainActor
final class KeroCLIService {
    static let shared = KeroCLIService()

    private static let notificationName = Notification.Name("sh.kero.cli")

    private struct CatalogTheme: Codable {
        let name: String
        let appearance: String
        let background: String
        let foreground: String
    }

    private struct CatalogState: Codable {
        let version: Int
        let appearance: String
        let selectedDark: String
        let selectedLight: String
        let themes: [CatalogTheme]
    }

    private struct ActivePreview {
        let id: String
        let pid: pid_t
    }

    private let secret = UUID().uuidString
    private let directoryURL: URL
    private let stateURL: URL
    private let automationSocketPath: String
    private var notificationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var previewMonitor: Timer?
    private var activePreview: ActivePreview?
    private var automationServer: KeroAutomationSocketServer?
    private var terminalCapabilities: [String: UUID] = [:]

    private init() {
        let fileManager = FileManager.default
        directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "kero-cli-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        stateURL = directoryURL.appendingPathComponent("themes.json")
        let socketNonce = UUID().uuidString.prefix(8)
        automationSocketPath = "/tmp/kero-\(getuid())-\(ProcessInfo.processInfo.processIdentifier)-\(socketNonce).sock"

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("kero: failed to prepare CLI state: \(error)")
        }

        writeState()

        do {
            automationServer = try KeroAutomationSocketServer(
                path: automationSocketPath
            ) { request, reply in
                Task { @MainActor in
                    reply(await KeroCLIService.shared.handleAutomation(request))
                }
            }
        } catch {
            NSLog("kero: failed to start automation socket: \(error)")
        }

        notificationObserver = DistributedNotificationCenter.default()
            .addObserver(
                forName: Self.notificationName,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handle(notification)
                }
            }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeStateDirectory()
            }
        }
    }

    /// Variables added to every Kero shell. The app executable's directory is
    /// prepended to the inherited PATH, making `kero` available without
    /// modifying a user's dotfiles or installing a global symlink.
    func terminalEnvironment(for sessionID: UUID) -> [String: String] {
        let capability = UUID().uuidString + UUID().uuidString
        terminalCapabilities[capability] = sessionID
        var environment = [
            "KERO_CLI_STATE": stateURL.path,
            "KERO_CLI_TOKEN": secret,
            "KERO_AUTOMATION": "1",
            "KERO_AUTOMATION_HELP": "kero +agent explain",
            "KERO_AUTOMATION_SOCKET": automationSocketPath,
            "KERO_AUTOMATION_TOKEN": capability,
            "KERO_TERMINAL_ID": sessionID.uuidString,
        ]
        if let skillURL = try? KeroAutomationSkill.bundledSkillURL() {
            environment["KERO_AUTOMATION_SKILL"] = skillURL.path
        }
        if let executableURL = Bundle.main.executableURL {
            let bin = executableURL.deletingLastPathComponent().path
            let inherited = ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = "\(bin):\(inherited)"
        }
        return environment
    }

    func revokeTerminal(id: UUID) {
        terminalCapabilities = terminalCapabilities.filter { $0.value != id }
    }

    private func handleAutomation(
        _ request: KeroAutomationRequest
    ) async -> KeroAutomationResponse {
        guard request.version == 1 else {
            return .failure(
                id: request.id,
                code: "unsupported_version",
                message: "Kero supports automation protocol version 1."
            )
        }
        guard let terminalID = UUID(uuidString: request.terminalID),
              terminalCapabilities[request.token] == terminalID
        else {
            return .failure(
                id: request.id,
                code: "unauthorized",
                message: "The terminal automation capability is invalid or expired."
            )
        }
        return await KeroAutomationRouter.route(
            request,
            callerTerminalID: terminalID
        )
    }

    private func handle(_ notification: Notification) {
        guard let info = notification.userInfo,
              info["token"] as? String == secret,
              let action = info["action"] as? String
        else { return }

        if action == "openProject" {
            guard let arguments = info["arguments"] as? [String],
                  arguments.count <= 256,
                  arguments.allSatisfy({ $0.utf8.count <= 16_384 }),
                  let directory = info["directory"] as? String
            else { return }
            let path = info["path"] as? String
            TerminalManager.openCLIProject(
                arguments: arguments,
                directory: directory,
                path: path
            )
            return
        }

        if action == "refresh" {
            writeState()
            return
        }

        guard let id = info["id"] as? String,
              let pidNumber = info["pid"] as? NSNumber
        else { return }
        let pid = pid_t(pidNumber.int32Value)
        guard pid > 1 else { return }

        switch action {
        case "preview":
            guard let name = info["theme"] as? String,
                  let dark = appearance(from: info),
                  processExists(pid)
            else { return }
            beginPreview(id: id, pid: pid, name: name, dark: dark)

        case "save":
            guard let name = info["theme"] as? String,
                  let dark = appearance(from: info),
                  Theme.isCommonTheme(named: name, dark: dark)
            else { return }
            savePreview(id: id, name: name, dark: dark)

        case "cancel":
            guard activePreview?.id == id else { return }
            restoreSavedSelection()

        default:
            break
        }
    }

    private func appearance(from info: [AnyHashable: Any]) -> Bool? {
        switch info["appearance"] as? String {
        case "dark": return true
        case "light": return false
        default: return nil
        }
    }

    private func beginPreview(id: String, pid: pid_t, name: String, dark: Bool) {
        guard Theme.previewSelection(named: name, dark: dark) else { return }
        activePreview = ActivePreview(id: id, pid: pid)

        // An explicit light/dark browse must be visible even when Kero is
        // currently forced to the opposite appearance. This override is
        // transient; save and cancel both restore the user's appearance mode.
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        TerminalManager.refreshAllAppearances()
        startPreviewMonitor()
    }

    private func savePreview(id: String, name: String, dark: Bool) {
        if let activePreview, activePreview.id != id { return }
        clearActivePreview()

        let settings = AppSettings.shared
        if dark {
            settings.themeDark = name
        } else {
            settings.themeLight = name
        }
        settings.applyAppearance()
        TerminalManager.refreshAllAppearances()
        writeState()
    }

    private func restoreSavedSelection() {
        clearActivePreview()
        let settings = AppSettings.shared
        Theme.reloadSelection(light: settings.themeLight, dark: settings.themeDark)
        settings.applyAppearance()
        TerminalManager.refreshAllAppearances()
        writeState()
    }

    private func clearActivePreview() {
        activePreview = nil
        previewMonitor?.invalidate()
        previewMonitor = nil
    }

    private func startPreviewMonitor() {
        guard previewMonitor == nil else { return }
        previewMonitor = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let preview = self.activePreview else { return }
                if !self.processExists(preview.pid) {
                    self.restoreSavedSelection()
                }
            }
        }
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func writeState() {
        let settings = AppSettings.shared
        let isDark: Bool
        if let application = NSApp {
            isDark = application.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
        } else {
            // `App.init` runs just before AppKit publishes `NSApp`. This value
            // is only the seed file; every CLI invocation requests a fresh
            // state after the application is fully running.
            isDark = settings.theme == .dark
        }
        let darkThemes = Theme.commonDarkThemes.map {
            CatalogTheme(
                name: $0.name,
                appearance: "dark",
                background: $0.background,
                foreground: $0.foreground
            )
        }
        let lightThemes = Theme.commonLightThemes.map {
            CatalogTheme(
                name: $0.name,
                appearance: "light",
                background: $0.background,
                foreground: $0.foreground
            )
        }
        let state = CatalogState(
            version: 1,
            appearance: isDark ? "dark" : "light",
            selectedDark: settings.themeDark,
            selectedLight: settings.themeLight,
            themes: darkThemes + lightThemes
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path
            )
        } catch {
            NSLog("kero: failed to write CLI theme catalog: \(error)")
        }
    }

    private func removeStateDirectory() {
        clearActivePreview()
        automationServer = nil
        terminalCapabilities = [:]
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
