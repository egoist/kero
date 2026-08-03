import SwiftUI

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var identityStore: IdentityStore

    private let existingHost: SSHHost?

    @State private var name: String
    @State private var hostname: String
    @State private var port: Int
    @State private var username: String
    @State private var authentication: SSHAuthenticationKind
    @State private var identityID: UUID?
    @State private var password = ""
    @State private var passwordRequiresUserPresence: Bool
    @State private var startsTmux: Bool
    @State private var isFavorite: Bool
    @State private var errorMessage: String?

    init(host: SSHHost?) {
        existingHost = host
        _name = State(initialValue: host?.name ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: host?.port ?? 22)
        _username = State(initialValue: host?.username ?? "")
        _authentication = State(initialValue: host?.authentication ?? .password)
        _identityID = State(initialValue: host?.identityID)
        #if DEBUG
        let defaultRequiresUserPresence =
            !ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        let defaultRequiresUserPresence = true
        #endif
        _passwordRequiresUserPresence = State(
            initialValue: host?.passwordRequiresUserPresence
                ?? defaultRequiresUserPresence
        )
        _startsTmux = State(initialValue: host?.startsTmux ?? false)
        _isFavorite = State(initialValue: host?.isFavorite ?? false)
    }

    private var isValid: Bool {
        let baseFieldsValid =
            SSHHost.isValidHostname(hostname)
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(port)

        switch authentication {
        case .password:
            let needsPassword = existingHost == nil
                || existingHost?.authentication != .password
            return baseFieldsValid && (!needsPassword || !password.isEmpty)
        case .identity:
            return baseFieldsValid && identityID != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    LabeledContent("Name") {
                        TextField("Production", text: $name)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.nickname)
                            .accessibilityIdentifier("host-name-field")
                    }

                    LabeledContent("Hostname") {
                        TextField("server.example.com", text: $hostname)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .accessibilityIdentifier("host-hostname-field")
                    }

                    LabeledContent("Port") {
                        TextField("22", value: $port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("host-port-field")
                    }

                    LabeledContent("Username") {
                        TextField("user", text: $username)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            // SSH credentials are not a website sign-in form.
                            // Mark both credential fields as transient input so
                            // Password AutoFill does not infer a login form.
                            .textContentType(.oneTimeCode)
                            .accessibilityIdentifier("host-username-field")
                    }
                }

                Section {
                    Picker("Authentication", selection: $authentication) {
                        ForEach(SSHAuthenticationKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authentication {
                    case .password:
                        LabeledContent(
                            existingHost == nil ? "Password" : "New Password"
                        ) {
                            SecureField(
                                existingHost == nil ? "Required" : "Unchanged",
                                text: $password
                            )
                            .multilineTextAlignment(.trailing)
                            // SSH credentials are not website logins. Kero owns their
                            // device-only Keychain lifecycle, so Password AutoFill would
                            // create a confusing second save prompt.
                            .textContentType(.oneTimeCode)
                            .accessibilityIdentifier("host-password-field")
                        }

                        Toggle(
                            "Require Face ID or passcode",
                            isOn: $passwordRequiresUserPresence
                        )
                    case .identity:
                        if identityStore.identities.isEmpty {
                            Label(
                                "Create a key from the Keys tab first.",
                                systemImage: "key.slash"
                            )
                            .foregroundStyle(.secondary)
                        } else {
                            Picker("SSH Key", selection: $identityID) {
                                Text("Choose a key").tag(nil as UUID?)
                                ForEach(identityStore.sortedIdentities) { identity in
                                    Text(identity.name).tag(identity.id as UUID?)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if authentication == .password {
                        Text(
                            "Credentials are stored only in this device’s Keychain. "
                            + "Kero never writes passwords into its host database."
                        )
                    } else {
                        Text("Only the public key and its label appear in app storage.")
                    }
                }

                Section {
                    Toggle("Resume with tmux", isOn: $startsTmux)
                    Toggle("Favorite", isOn: $isFavorite)
                } header: {
                    Text("Session")
                } footer: {
                    if startsTmux {
                        Text("Kero runs “tmux new-session -A -s kero” after connecting.")
                    } else {
                        Text("Kero opens the server’s default interactive shell.")
                    }
                }
            }
            .navigationTitle(existingHost == nil ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
            .onChange(of: authentication) { _, newValue in
                if newValue == .identity, identityID == nil {
                    identityID = identityStore.sortedIdentities.first?.id
                }
            }
            .alert(
                "Couldn’t save host",
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

    private func save() {
        let cleanHostname = SSHHost.normalizeHostnameInput(hostname)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = SSHHost(
            id: existingHost?.id ?? UUID(),
            name: cleanName.isEmpty ? cleanHostname : cleanName,
            hostname: cleanHostname,
            port: port,
            username: cleanUsername,
            authentication: authentication,
            identityID: authentication == .identity ? identityID : nil,
            passwordRequiresUserPresence: passwordRequiresUserPresence,
            startsTmux: startsTmux,
            isFavorite: isFavorite,
            lastConnectedAt: existingHost?.lastConnectedAt
        )

        do {
            try hostStore.upsert(
                host,
                password: authentication == .password && !password.isEmpty
                    ? password
                    : nil
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
