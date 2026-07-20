//
//  Updater.swift
//  kero
//

import Combine
import Sparkle
import SwiftUI

/// App-wide Sparkle updater. A single instance owns the update lifecycle; the
/// "Check for Updates…" menu item and the Settings toggle both drive it.
///
/// The feed URL and the public EdDSA key are read from Info.plist, injected via
/// the `INFOPLIST_KEY_SUFeedURL` and `INFOPLIST_KEY_SUPublicEDKey` build
/// settings. See RELEASING.md for generating the signing keys and publishing
/// updates.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    /// Gates the menu item: Sparkle can't start a check while one is already in
    /// flight, so the command disables itself until it's ready again.
    @Published private(set) var canCheckForUpdates = false

    /// Whether Sparkle checks for updates on its own schedule. Sparkle owns the
    /// persisted value (in `UserDefaults`); this mirror lets Settings bind to
    /// it and writes changes straight back through.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private init() {
        // Don't run the updater in debug builds. Starting it schedules a
        // background check and pops Sparkle's "check for updates
        // automatically?" permission prompt, which is just noise while
        // developing. Release builds start it and behave normally.
        #if DEBUG
        let startImmediately = false
        #else
        let startImmediately = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startImmediately,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Seed from Sparkle's persisted value; didSet doesn't fire here.
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Runs Sparkle's user-facing update check (progress window and prompts).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// The "Check for Updates…" application-menu command.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
