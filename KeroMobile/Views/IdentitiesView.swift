import SwiftUI
import UIKit

struct IdentitiesView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var identityStore: IdentityStore
    @EnvironmentObject private var hostStore: HostStore

    @State private var isAddingIdentity = false
    @State private var identityPendingDeletion: SSHIdentity?
    @State private var blockedDeletionMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if identityStore.identities.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(identityStore.sortedIdentities) { identity in
                                NavigationLink(value: identity) {
                                    IdentityRow(identity: identity)
                                }
                                .contextMenu {
                                    Button("Copy Public Key", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = identity.publicKey
                                    }

                                    ShareLink(
                                        item: identity.publicKey,
                                        subject: Text(identity.name)
                                    ) {
                                        Label("Share Public Key", systemImage: "square.and.arrow.up")
                                    }

                                    Divider()

                                    Button(
                                        "Delete",
                                        systemImage: "trash",
                                        role: .destructive
                                    ) {
                                        requestDeletion(of: identity)
                                    }
                                }
                                .swipeActions(allowsFullSwipe: false) {
                                    Button(
                                        "Delete",
                                        systemImage: "trash",
                                        role: .destructive
                                    ) {
                                        requestDeletion(of: identity)
                                    }
                                }
                            }
                        } footer: {
                            Text(
                                "Private keys never leave the Keychain. "
                                + "Tap a key to copy or share its public half."
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Keys")
            .navigationDestination(for: SSHIdentity.self) { identity in
                IdentityDetailView(identity: identity)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Generate Key", systemImage: "plus") {
                        isAddingIdentity = true
                    }
                }
            }
            .sheet(isPresented: $isAddingIdentity) {
                GenerateIdentityView()
            }
            .alert(
                "Delete \(identityPendingDeletion?.name ?? "key")?",
                isPresented: Binding(
                    get: { identityPendingDeletion != nil },
                    set: { if !$0 { identityPendingDeletion = nil } }
                ),
                presenting: identityPendingDeletion
            ) { identity in
                Button("Delete", role: .destructive) {
                    do {
                        try identityStore.delete(identity)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    identityPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    identityPendingDeletion = nil
                }
            } message: { _ in
                Text("The private key will be permanently removed from this device.")
            }
            .alert(
                "Key is in use",
                isPresented: Binding(
                    get: { blockedDeletionMessage != nil },
                    set: { if !$0 { blockedDeletionMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(blockedDeletionMessage ?? "")
            }
            .alert(
                "Couldn’t delete key",
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

    private func requestDeletion(of identity: SSHIdentity) {
        let referencingHosts = hostStore.hosts.filter {
            $0.authentication == .identity && $0.identityID == identity.id
        }
        if referencingHosts.isEmpty {
            identityPendingDeletion = identity
        } else {
            let names = referencingHosts
                .map(\.displayName)
                .sorted()
                .joined(separator: ", ")
            blockedDeletionMessage =
                "Change authentication for \(names) before deleting this key."
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                emptyStateContent
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .padding(.bottom, 100)
            }
        } else {
            emptyStateContent
        }
    }

    private var emptyStateContent: some View {
        ContentUnavailableView {
            Label("No SSH Keys", systemImage: "key")
        } description: {
            Text(
                "Generate an Ed25519 key, then add its public key "
                + "to a server’s authorized_keys file."
            )
        } actions: {
            Button("Generate Key", systemImage: "plus") {
                isAddingIdentity = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct IdentityDetailView: View {
    let identity: SSHIdentity

    @State private var copied = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(identity.name, systemImage: "key.fill")
                        .font(.title3.bold())

                    Text(identity.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    LabeledContent(
                        "Protection",
                        value: identity.requiresUserPresence
                            ? "Face ID or passcode"
                            : "Device Keychain"
                    )
                    .font(.subheadline)

                    LabeledContent(
                        "Created",
                        value: identity.createdAt.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    .font(.subheadline)
                }
                .padding(.vertical, 5)
            }

            Section("Public Key") {
                Text(identity.publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("identity-public-key")

                Button(
                    copied ? "Copied" : "Copy Public Key",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                ) {
                    UIPasteboard.general.string = identity.publicKey
                    copied = true
                }

                ShareLink(
                    item: identity.publicKey,
                    subject: Text(identity.name)
                ) {
                    Label("Share Public Key", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Text(
                    "Add this complete public-key line to ~/.ssh/authorized_keys "
                    + "on the server, then choose this key when editing a host."
                )
            } header: {
                Text("Set Up a Server")
            } footer: {
                Text(
                    "Kero never exposes or exports the private key. "
                    + "Deleting this key is permanent."
                )
            }
        }
        .navigationTitle("SSH Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IdentityRow: View {
    let identity: SSHIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(identity.name, systemImage: "key.fill")
                    .font(.headline)
                Spacer()
                if identity.requiresUserPresence {
                    Image(systemName: "faceid")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Protected by user presence")
                }
            }

            Text(identity.fingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Created \(identity.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct GenerateIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var identityStore: IdentityStore

    @State private var name = "Kero"
    @State private var requiresUserPresence = true
    @State private var errorMessage: String?

    init() {
        #if DEBUG
        let defaultRequiresUserPresence =
            !ProcessInfo.processInfo.arguments.contains("-ui-testing")
        #else
        let defaultRequiresUserPresence = true
        #endif
        _requiresUserPresence = State(
            initialValue: defaultRequiresUserPresence
        )
    }

    private var canGenerate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("Name", text: $name)
                        .textContentType(.nickname)
                        .accessibilityIdentifier("identity-name-field")

                    LabeledContent("Type", value: "Ed25519")
                }

                Section {
                    Toggle(
                        "Require Face ID or passcode",
                        isOn: $requiresUserPresence
                    )
                } footer: {
                    Text(
                        "The private key is generated on this device and stored "
                        + "in the Keychain. Only its public key can be copied or shared."
                    )
                }
            }
            .navigationTitle("Generate Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        generate()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canGenerate)
                }
            }
            .alert(
                "Couldn’t generate key",
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
        .presentationDetents([.medium])
    }

    private func generate() {
        do {
            try identityStore.generate(
                name: name,
                requiresUserPresence: requiresUserPresence
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
