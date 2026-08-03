import SwiftUI

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: TerminalSessionStore
    @AppStorage("terminal.fontSize") private var fontSize = 14.0

    @ObservedObject var session: TerminalSessionModel
    @State private var projectPanel: TerminalProjectPanel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TerminalRepresentable(session: session, fontSize: fontSize)
                .accessibilityLabel("Terminal for \(session.host.displayName)")
                .accessibilityIdentifier("ssh-terminal")
                .privacySensitive()
                .allowsHitTesting(session.state == .connected)

            if session.state == .connecting {
                VStack {
                    HStack(spacing: 9) {
                        ProgressView()
                            .tint(.white)
                        Text("Connecting to \(session.host.endpoint)…")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(1)
            } else if case .failed(let message) = session.state {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Connection ended")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        session.reconnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reconnect-session")
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .zIndex(1)
            } else if session.state == .disconnected {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Session ended")
                        .font(.headline)
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        session.reconnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reconnect-session")
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .zIndex(1)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalKeysBar(session: session)
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(1)
                    .accessibilityIdentifier("terminal-title")
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Files", systemImage: "folder") {
                    projectPanel = .files
                }
                .accessibilityIdentifier("terminal-files")

                Button("Git", systemImage: "arrow.triangle.branch") {
                    projectPanel = .git
                }
                .accessibilityIdentifier("terminal-git")

                Menu {
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        session.reconnect()
                    }

                    Divider()

                    Button(
                        "Close Session",
                        systemImage: "xmark.circle",
                        role: .destructive
                    ) {
                        sessionStore.close(session)
                        dismiss()
                    }
                } label: {
                    Label("Session", systemImage: statusSymbol)
                }
                .accessibilityLabel("Session actions")
                .accessibilityValue(
                    "\(session.statusText), "
                        + "\(session.host.username)@\(session.host.endpoint)"
                )
            }
        }
        .sheet(item: $projectPanel) { panel in
            TerminalProjectSheet(
                session: session,
                initialPanel: panel
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $session.hostKeyPrompt) { prompt in
            HostKeyTrustView(
                prompt: prompt,
                accept: session.acceptHostKey,
                reject: session.rejectHostKey
            )
            .interactiveDismissDisabled()
        }
        .alert(item: $session.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            session.becameVisible()
        }
        .onDisappear {
            session.becameHidden()
        }
    }

    private var statusSymbol: String {
        switch session.state {
        case .connected:
            "checkmark.circle.fill"
        case .connecting:
            "ellipsis.circle"
        case .failed:
            "exclamationmark.circle.fill"
        case .idle, .disconnected:
            "circle"
        }
    }
}

private struct TerminalRepresentable: UIViewRepresentable {
    let session: TerminalSessionModel
    let fontSize: Double

    func makeUIView(context: Context) -> KeroTerminalView {
        let view = session.terminalView
        view.setFontSize(CGFloat(fontSize))
        #if DEBUG
        let shouldFocus = !ProcessInfo.processInfo.arguments.contains(
            "-ui-testing-no-keyboard"
        )
        #else
        let shouldFocus = true
        #endif
        if shouldFocus {
            DispatchQueue.main.async {
                _ = view.becomeFirstResponder()
            }
        }
        return view
    }

    func updateUIView(_ uiView: KeroTerminalView, context: Context) {
        uiView.setFontSize(CGFloat(fontSize))
    }
}

private struct TerminalKeysBar: View {
    @ObservedObject var session: TerminalSessionModel
    @State private var scrollEdges = KeyScrollEdges(
        canScrollLeading: false,
        canScrollTrailing: true
    )

    private let keys: [TerminalKey] = [
        TerminalKey(label: "Esc", accessibilityLabel: "Escape", bytes: [0x1b]),
        TerminalKey(label: "Tab", accessibilityLabel: "Tab", bytes: [0x09]),
        TerminalKey(label: "⌃C", accessibilityLabel: "Control C", bytes: [0x03]),
        TerminalKey(label: "⌃D", accessibilityLabel: "Control D", bytes: [0x04]),
        TerminalKey(label: "←", accessibilityLabel: "Left arrow", bytes: [0x1b, 0x5b, 0x44]),
        TerminalKey(label: "↓", accessibilityLabel: "Down arrow", bytes: [0x1b, 0x5b, 0x42]),
        TerminalKey(label: "↑", accessibilityLabel: "Up arrow", bytes: [0x1b, 0x5b, 0x41]),
        TerminalKey(label: "→", accessibilityLabel: "Right arrow", bytes: [0x1b, 0x5b, 0x43]),
        TerminalKey(label: "Home", accessibilityLabel: "Home", bytes: [0x1b, 0x5b, 0x48]),
        TerminalKey(label: "End", accessibilityLabel: "End", bytes: [0x1b, 0x5b, 0x46])
    ]

    var body: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(keys) { key in
                        Button {
                            session.send(bytes: key.bytes)
                        } label: {
                            Text(key.label)
                                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(
                            Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .accessibilityLabel(key.accessibilityLabel)
                    }
                }
                .padding(.leading, 10)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: KeyScrollEdges.self) { geometry in
                let minimumOffset = -geometry.contentInsets.leading
                let maximumOffset = max(
                    minimumOffset,
                    geometry.contentSize.width
                        - geometry.containerSize.width
                        + geometry.contentInsets.trailing
                )

                return KeyScrollEdges(
                    canScrollLeading:
                        geometry.contentOffset.x > minimumOffset + 0.5,
                    canScrollTrailing:
                        geometry.contentOffset.x < maximumOffset - 0.5
                )
            } action: { _, newEdges in
                scrollEdges = newEdges
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            scrollEdges.canScrollLeading ? .clear : .black,
                            .black,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 22)

                    Color.black

                    LinearGradient(
                        colors: [
                            .black,
                            scrollEdges.canScrollTrailing ? .clear : .black,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 22)
                }
                .animation(.easeOut(duration: 0.14), value: scrollEdges)
            }
            .accessibilityIdentifier("terminal-key-scroll")

            Button {
                session.focusTerminal()
            } label: {
                Image(systemName: "keyboard")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .accessibilityLabel("Show Keyboard")
            .accessibilityIdentifier("terminal-keyboard")
            .padding(.trailing, 10)
        }
        .padding(.vertical, 8)
        .background(.black.opacity(0.96))
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.16))
        }
    }
}

private struct KeyScrollEdges: Equatable {
    let canScrollLeading: Bool
    let canScrollTrailing: Bool
}

private struct TerminalKey: Identifiable {
    let id = UUID()
    let label: String
    let accessibilityLabel: String
    let bytes: [UInt8]
}

private struct HostKeyTrustView: View {
    let prompt: HostKeyPrompt
    let accept: () -> Void
    let reject: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label {
                        Text(
                            prompt.kind == .changed
                                ? "Server identity changed"
                                : "Verify server identity"
                        )
                        .font(.title2.bold())
                    } icon: {
                        Image(
                            systemName: prompt.kind == .changed
                                ? "exclamationmark.triangle.fill"
                                : "lock.shield.fill"
                        )
                        .foregroundStyle(
                            prompt.kind == .changed ? Color.red : Color.accentColor
                        )
                    }

                    Text(explanation)
                        .foregroundStyle(.secondary)

                    fingerprintCard(
                        title: prompt.kind == .changed ? "New fingerprint" : "Fingerprint",
                        value: prompt.proposed.fingerprint,
                        tint: prompt.kind == .changed ? .red : .accentColor
                    )

                    if let existing = prompt.existing {
                        fingerprintCard(
                            title: "Previously trusted",
                            value: existing.fingerprint,
                            tint: .secondary
                        )
                    }

                    Text(
                        "Compare this SHA-256 fingerprint with one provided by "
                        + "your server administrator through a trusted channel."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        accept()
                    } label: {
                        Text(
                            prompt.kind == .changed
                                ? "Trust New Key and Connect"
                                : "Trust and Connect"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(
                        prompt.kind == .changed
                            ? Color.red
                            : Color.accentColor
                    )
                    .controlSize(.large)

                    Button("Cancel", role: .cancel) {
                        reject()
                    }
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(prompt.proposed.endpoint)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var explanation: String {
        if prompt.kind == .changed {
            return "The server presented a different host key. This can mean the "
                + "server was rebuilt, but it can also indicate an interception attempt."
        }
        return "This is the first time Kero has connected to this server."
    }

    private func fingerprintCard(
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}
