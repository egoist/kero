import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var identityStore: IdentityStore
    @EnvironmentObject private var knownHostStore: KnownHostStore
    @EnvironmentObject private var sessionStore: TerminalSessionStore
    @AppStorage("terminal.fontSize") private var terminalFontSize = 14.0

    @State private var recordPendingForget: KnownHostRecord?
    @State private var showsEraseConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text("\(Int(terminalFontSize)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)

                            Stepper(
                                "Terminal font size",
                                value: $terminalFontSize,
                                in: 10...24,
                                step: 1
                            )
                            .labelsHidden()
                        }
                    } label: {
                        Label("Font Size", systemImage: "textformat.size")
                    }
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Hardware keyboards and standard iOS text input are supported.")
                }

                Section {
                    if knownHostStore.records.isEmpty {
                        Text("No server identities have been trusted yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(knownHostStore.records) { record in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.endpoint)
                                    .font(.body.monospaced())
                                Text(record.fingerprint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("Trusted \(record.trustedAt, style: .date)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .swipeActions(allowsFullSwipe: false) {
                                Button(
                                    "Forget",
                                    systemImage: "trash",
                                    role: .destructive
                                ) {
                                    recordPendingForget = record
                                }
                            }
                        }
                    }
                } header: {
                    Text("Trusted Hosts")
                } footer: {
                    Text(
                        "Kero verifies a server against the key you trusted on its "
                        + "first connection and warns before accepting a changed key."
                    )
                }

                Section("Privacy & Support") {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    Link(
                        destination: URL(string: "mailto:hi@egoist.dev")!
                    ) {
                        Label("Email Support", systemImage: "envelope")
                    }

                    Link(
                        destination: URL(string: "https://kero.sh")!
                    ) {
                        Label("Kero Website", systemImage: "safari")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showsEraseConfirmation = true
                    } label: {
                        Label {
                            Text("Erase All Data…")
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                } footer: {
                    Text(
                        "Removes every saved host, password, private key, trusted "
                        + "server identity, and terminal preference from this device."
                    )
                }

                Section("About") {
                    LabeledContent("App", value: "Kero")
                    LabeledContent(
                        "Version",
                        value: versionDescription
                    )

                    NavigationLink {
                        OpenSourceNoticesView()
                    } label: {
                        Text("Open Source Licenses")
                    }

                    Link(
                        "Source Code",
                        destination: URL(string: "https://github.com/egoist/kero")!
                    )
                }
            }
            .navigationTitle("Settings")
            .alert(
                "Forget \(recordPendingForget?.endpoint ?? "server")?",
                isPresented: Binding(
                    get: { recordPendingForget != nil },
                    set: { if !$0 { recordPendingForget = nil } }
                ),
                presenting: recordPendingForget
            ) { record in
                Button("Forget", role: .destructive) {
                    do {
                        try knownHostStore.delete(record)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    recordPendingForget = nil
                }
                Button("Cancel", role: .cancel) {
                    recordPendingForget = nil
                }
            } message: { _ in
                Text(
                    "Kero will ask you to verify this server’s fingerprint "
                    + "the next time you connect."
                )
            }
            .alert(
                "Erase all Kero data?",
                isPresented: $showsEraseConfirmation
            ) {
                Button("Erase All Data", role: .destructive) {
                    eraseAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This permanently deletes all SSH credentials and settings "
                    + "stored by Kero on this device. This action cannot be undone."
                )
            }
            .alert(
                "Couldn’t complete the change",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func eraseAllData() {
        do {
            sessionStore.closeAll()
            try hostStore.deleteAll()
            try identityStore.deleteAll()
            try knownHostStore.deleteAll()
            terminalFontSize = 14
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
