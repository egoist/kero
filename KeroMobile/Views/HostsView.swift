import SwiftUI

struct HostsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionStore: TerminalSessionStore

    @State private var path: [SessionRoute] = []
    @State private var searchText = ""
    @State private var editor: HostEditorItem?
    @State private var hostPendingDeletion: SSHHost?
    @State private var errorMessage: String?

    private var filteredHosts: [SSHHost] {
        guard !searchText.isEmpty else {
            return hostStore.sortedHosts
        }
        return hostStore.sortedHosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.hostname.localizedCaseInsensitiveContains(searchText)
                || $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredSessions: [TerminalSessionModel] {
        guard !searchText.isEmpty else {
            return sessionStore.sessions
        }
        return sessionStore.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.host.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.host.hostname.localizedCaseInsensitiveContains(searchText)
                || $0.host.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var hasSearchResults: Bool {
        !filteredHosts.isEmpty || !filteredSessions.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if hostStore.hosts.isEmpty && sessionStore.sessions.isEmpty {
                    emptyState
                } else if !hasSearchResults {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        if !filteredSessions.isEmpty {
                            Section("Active Sessions") {
                                activeSessions
                            }
                        }

                        if !filteredHosts.isEmpty {
                            Section("Hosts") {
                                ForEach(filteredHosts) { host in
                                    Button {
                                        openSession(for: host)
                                    } label: {
                                        HostRow(host: host)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(
                                            host.isFavorite
                                                ? "Remove Favorite"
                                                : "Favorite",
                                            systemImage: host.isFavorite
                                                ? "star.slash"
                                                : "star"
                                        ) {
                                            toggleFavorite(host)
                                        }

                                        Button("Edit", systemImage: "pencil") {
                                            editor = HostEditorItem(host: host)
                                        }

                                        Divider()

                                        Button(
                                            "Delete",
                                            systemImage: "trash",
                                            role: .destructive
                                        ) {
                                            hostPendingDeletion = host
                                        }
                                    }
                                    .swipeActions(
                                        edge: .leading,
                                        allowsFullSwipe: true
                                    ) {
                                        Button {
                                            toggleFavorite(host)
                                        } label: {
                                            Label(
                                                host.isFavorite
                                                    ? "Unfavorite"
                                                    : "Favorite",
                                                systemImage: host.isFavorite
                                                    ? "star.slash"
                                                    : "star"
                                            )
                                        }
                                        .tint(.yellow)
                                    }
                                    .swipeActions(
                                        edge: .trailing,
                                        allowsFullSwipe: false
                                    ) {
                                        Button(
                                            "Delete",
                                            systemImage: "trash",
                                            role: .destructive
                                        ) {
                                            hostPendingDeletion = host
                                        }

                                        Button("Edit", systemImage: "pencil") {
                                            editor = HostEditorItem(host: host)
                                        }
                                        .tint(.blue)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Hosts")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Name, host, or user"
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") {
                        editor = HostEditorItem(host: nil)
                    }
                }
            }
            .navigationDestination(for: SessionRoute.self) { route in
                if let session = sessionStore.session(
                    forHostID: route.hostID
                ) {
                    TerminalScreen(session: session)
                } else {
                    ContentUnavailableView(
                        "Session Closed",
                        systemImage: "terminal",
                        description: Text(
                            "Return to Hosts to start another SSH session."
                        )
                    )
                }
            }
            .sheet(item: $editor) { item in
                HostEditorView(host: item.host)
            }
            .alert(
                "Delete \(hostPendingDeletion?.displayName ?? "host")?",
                isPresented: Binding(
                    get: { hostPendingDeletion != nil },
                    set: { if !$0 { hostPendingDeletion = nil } }
                ),
                presenting: hostPendingDeletion
            ) { host in
                Button("Delete", role: .destructive) {
                    do {
                        try hostStore.delete(host)
                        sessionStore.closeSession(forHostID: host.id)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    hostPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    hostPendingDeletion = nil
                }
            } message: { host in
                Text("This removes the host and its saved password from this device.")
            }
            .alert(
                "Couldn’t update host",
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

    private func toggleFavorite(_ host: SSHHost) {
        do {
            try hostStore.toggleFavorite(host)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSession(for host: SSHHost) {
        let session = sessionStore.openSession(for: host)
        path.append(SessionRoute(hostID: session.host.id))
    }

    @ViewBuilder
    private var activeSessions: some View {
        LazyVGrid(
            columns: activeSessionColumns,
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(filteredSessions) { session in
                ActiveSessionTile(
                    session: session,
                    open: {
                        path.append(
                            SessionRoute(hostID: session.host.id)
                        )
                    },
                    close: {
                        sessionStore.close(session)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .listRowInsets(
            EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16)
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var activeSessionColumns: [GridItem] {
        return Array(
            repeating: GridItem(
                .flexible(minimum: 0, maximum: .infinity),
                spacing: 12,
                alignment: .top
            ),
            count: 2
        )
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
            Label("No Hosts", systemImage: "terminal")
        } description: {
            Text("Add an SSH host to start a terminal session.")
        } actions: {
            Button("Add Host", systemImage: "plus") {
                editor = HostEditorItem(host: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct SessionRoute: Hashable {
    let hostID: UUID
}

private struct ActiveSessionTile: View {
    @ObservedObject var session: TerminalSessionModel

    let open: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    preview

                    Text(session.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(session.host.displayName), \(session.statusText)"
            )
            .accessibilityValue(session.title)
            .accessibilityHint("Resumes this terminal session")
            .accessibilityIdentifier("active-session-card")

            Button(role: .destructive, action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.78), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(
                "Close session for \(session.host.displayName)"
            )
            .accessibilityIdentifier("close-active-session")
            .padding(2)
        }
        .privacySensitive()
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            if let thumbnail = session.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.title2.weight(.medium))
                    Text(session.title)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 32)
                .accessibilityHidden(true)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Text(session.host.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.black.opacity(0.62), in: Capsule())
            .padding(8)
            .padding(.trailing, 40)
            .accessibilityHidden(true)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .clipped()
    }

    private var statusColor: Color {
        switch session.state {
        case .connected:
            .green
        case .connecting:
            .orange
        case .failed:
            .red
        case .idle, .disconnected:
            .secondary
        }
    }
}

private struct HostRow: View {
    let host: SSHHost

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "terminal.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if host.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }

                Text("\(host.username)@\(host.endpoint)")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let lastConnectedAt = host.lastConnectedAt {
                    Text("Connected \(lastConnectedAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(host.authentication.title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens an SSH terminal")
    }
}

private struct HostEditorItem: Identifiable {
    let id = UUID()
    let host: SSHHost?
}
