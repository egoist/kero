import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section {
                Label("No account", systemImage: "person.crop.circle.badge.xmark")
                Label("No analytics or telemetry", systemImage: "chart.bar.xaxis")
                Label("No advertising or tracking", systemImage: "eye.slash")
            } header: {
                Text("At a Glance")
            } footer: {
                Text(
                    "Kero’s developer does not receive your hosts, credentials, "
                    + "terminal activity, or usage data."
                )
            }

            Section("Stored on This Device") {
                privacyRow(
                    "Hosts and trusted server fingerprints",
                    detail: "Protected app storage"
                )
                privacyRow(
                    "Passwords and private SSH keys",
                    detail: "Device-only Keychain"
                )
                privacyRow(
                    "Terminal font size",
                    detail: "Private app preferences"
                )
            }

            Section {
                Text(
                    "When you connect, Kero communicates directly with the SSH "
                    + "server you chose. That server and its operator can receive "
                    + "your username, authentication attempt, commands, and terminal "
                    + "traffic according to the server’s own policies."
                )

                Text(
                    "Kero does not proxy terminal traffic through a Kero service."
                )
            } header: {
                Text("Network Connections")
            }

            Section {
                Text(
                    "A remote terminal may ask Kero to copy text to the system "
                    + "clipboard. Kero never permits a remote process to read your "
                    + "clipboard."
                )
            } header: {
                Text("Clipboard")
            }

            Section {
                Text(
                    "Delete individual hosts and keys from their lists, forget "
                    + "server identities here in Settings, or use Erase All Data "
                    + "to remove everything Kero stores on this device."
                )
            } header: {
                Text("Your Control")
            }

            Section {
                LabeledContent("Effective", value: "July 29, 2026")
                Link(
                    "Questions or Support",
                    destination: URL(string: "mailto:hi@egoist.dev")!
                )
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
