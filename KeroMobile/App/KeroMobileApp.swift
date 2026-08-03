import SwiftUI

@main
struct KeroMobileApp: App {
    @StateObject private var hostStore: HostStore
    @StateObject private var identityStore: IdentityStore
    @StateObject private var knownHostStore: KnownHostStore
    @StateObject private var sessionStore: TerminalSessionStore

    init() {
        MobileTerminalFont.registerBundledFonts()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-live-ssh-testing") {
            let environment = ProcessInfo.processInfo.environment
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("KeroMobileLiveSSHTests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let keychain = KeychainStore(
                service: "sh.kero.mobile.live-tests.\(ProcessInfo.processInfo.processIdentifier)"
            )
            let hostStore = HostStore(
                storageURL: root.appendingPathComponent("hosts.json"),
                keychain: keychain
            )
            if let hostname = environment["KERO_LIVE_SSH_HOST"],
               let username = environment["KERO_LIVE_SSH_USERNAME"],
               let password = environment["KERO_LIVE_SSH_PASSWORD"] {
                let host = SSHHost(
                    name: "Live SSH Test",
                    hostname: hostname,
                    port: Int(environment["KERO_LIVE_SSH_PORT"] ?? "") ?? 22,
                    username: username,
                    passwordRequiresUserPresence:
                        environment["KERO_LIVE_SSH_USER_PRESENCE"] == "1"
                )
                try? hostStore.upsert(host, password: password)
            }
            let identityStore = IdentityStore(
                storageURL: root.appendingPathComponent("identities.json"),
                keychain: keychain
            )
            let knownHostStore = KnownHostStore(
                storageURL: root.appendingPathComponent("known-hosts.json")
            )
            _hostStore = StateObject(wrappedValue: hostStore)
            _identityStore = StateObject(wrappedValue: identityStore)
            _knownHostStore = StateObject(wrappedValue: knownHostStore)
            let sessionStore = TerminalSessionStore(
                hostStore: hostStore,
                identityStore: identityStore,
                knownHostStore: knownHostStore
            )
            _sessionStore = StateObject(wrappedValue: sessionStore)
            return
        }

        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("KeroMobileUITests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let keychain = KeychainStore(
                service: "sh.kero.mobile.ui-tests.\(ProcessInfo.processInfo.processIdentifier)"
            )
            let hostStore = HostStore(
                storageURL: root.appendingPathComponent("hosts.json"),
                keychain: keychain
            )
            let identityStore = IdentityStore(
                storageURL: root.appendingPathComponent("identities.json"),
                keychain: keychain
            )
            let knownHostStore = KnownHostStore(
                storageURL: root.appendingPathComponent("known-hosts.json")
            )
            _hostStore = StateObject(wrappedValue: hostStore)
            _identityStore = StateObject(wrappedValue: identityStore)
            _knownHostStore = StateObject(wrappedValue: knownHostStore)
            let sessionStore = TerminalSessionStore(
                hostStore: hostStore,
                identityStore: identityStore,
                knownHostStore: knownHostStore
            )
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ui-testing-active-sessions")
                || arguments.contains("-ui-testing-single-active-session")
                || arguments.contains("-ui-testing-project-panels") {
                let hosts = [
                    SSHHost(
                        name: "Build Server",
                        hostname: "192.0.2.10",
                        username: "builder"
                    ),
                    SSHHost(
                        name: "Home Server",
                        hostname: "192.0.2.11",
                        username: "admin"
                    ),
                ]
                let sessionCount =
                    arguments.contains("-ui-testing-single-active-session")
                        || arguments.contains("-ui-testing-project-panels")
                    ? 1
                    : 2
                for (index, host) in hosts.prefix(sessionCount).enumerated() {
                    let session = sessionStore.openSession(for: host)
                    session.terminalView.receive(
                        """
                        Last login: Wed Jul 29 18:40:47 2026
                        Welcome to fish, the friendly interactive shell
                        Type help for instructions on how to use fish
                        builder in build-server in ~
                        > 
                        """
                    )
                    session.updateTitle("[\(host.displayName)] ~")
                    session.captureThumbnail()
                    if index == 0,
                       arguments.contains("-ui-testing-project-panels") {
                        let gitPreview: RemoteGitSnapshot? = arguments.contains(
                            "-ui-testing-project-no-repository"
                        )
                            ? nil
                            : RemoteGitSnapshot(
                                repositoryRoot: "/Users/builder/kero",
                                branch: "main",
                                headOID: "751864f616a4563d5e0abcc9b52f1f530c0f18e2",
                                upstream: "origin/main",
                                ahead: 1,
                                behind: 2,
                                entries: [
                                    RemoteGitEntry(
                                        path: "README.md",
                                        stagedStatus: "M",
                                        worktreeStatus: "."
                                    ),
                                    RemoteGitEntry(
                                        path: "Sources/App.swift",
                                        stagedStatus: ".",
                                        worktreeStatus: "M"
                                    ),
                                    RemoteGitEntry(
                                        path: "Notes.md",
                                        stagedStatus: "?",
                                        worktreeStatus: "."
                                    ),
                                ],
                                branches: [
                                    "feature/mobile-source-control",
                                    "main",
                                    "release/0.0.1",
                                ],
                                remotes: ["origin"],
                                recentCommits: [
                                    RemoteGitCommit(
                                        hash: "751864f616a4563d5e0abcc9b52f1f530c0f18e2",
                                        shortHash: "751864f",
                                        subject: "Polish mobile terminal header",
                                        author: "Egoist",
                                        date: Date(timeIntervalSince1970: 1_775_011_200)
                                    ),
                                    RemoteGitCommit(
                                        hash: "4af2b601cd9c93498d987f2cbd5676f2fa4a735d",
                                        shortHash: "4af2b60",
                                        subject: "Add remote project browser",
                                        author: "Egoist",
                                        date: Date(timeIntervalSince1970: 1_774_924_800)
                                    ),
                                ],
                                stashCount: 1
                            )
                        session.remoteProject.installPreview(
                            root: "/Users/builder/kero",
                            files: [
                                RemoteFileItem(
                                    name: "Sources",
                                    path: "/Users/builder/kero/Sources",
                                    isDirectory: true,
                                    depth: 0
                                ),
                                RemoteFileItem(
                                    name: "Package.swift",
                                    path: "/Users/builder/kero/Package.swift",
                                    isDirectory: false,
                                    depth: 0
                                ),
                                RemoteFileItem(
                                    name: "README.md",
                                    path: "/Users/builder/kero/README.md",
                                    isDirectory: false,
                                    depth: 0
                                ),
                            ],
                            git: gitPreview
                        )
                    }
                }
            }
            _sessionStore = StateObject(wrappedValue: sessionStore)
            return
        }
        #endif

        let keychain = KeychainStore()
        let hostStore = HostStore(keychain: keychain)
        let identityStore = IdentityStore(keychain: keychain)
        let knownHostStore = KnownHostStore()
        _hostStore = StateObject(wrappedValue: hostStore)
        _identityStore = StateObject(wrappedValue: identityStore)
        _knownHostStore = StateObject(wrappedValue: knownHostStore)
        _sessionStore = StateObject(
            wrappedValue: TerminalSessionStore(
                hostStore: hostStore,
                identityStore: identityStore,
                knownHostStore: knownHostStore
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(hostStore)
                .environmentObject(identityStore)
                .environmentObject(knownHostStore)
                .environmentObject(sessionStore)
        }
    }
}
