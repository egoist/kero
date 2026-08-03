import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var sessionStore: TerminalSessionStore
    @State private var selection: AppTab = .hosts
    @State private var backgroundTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $selection) {
            Tab("Hosts", systemImage: "terminal", value: .hosts) {
                HostsView()
            }

            Tab("Keys", systemImage: "key", value: .keys) {
                IdentitiesView()
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
        }
        .overlay {
            if scenePhase != .active {
                PrivacyShield()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            backgroundTask?.cancel()
            backgroundTask = nil

            switch newPhase {
            case .active:
                sessionStore.resumeVisibleSessions()
            case .background:
                backgroundTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return
                    }
                    sessionStore.suspendForBackground()
                    backgroundTask = nil
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

private enum AppTab: Hashable {
    case hosts
    case keys
    case settings
}

private struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Kero")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
        .accessibilityHidden(true)
    }
}
