import Crypto
import Foundation
import NIOSSH
import UIKit
import XCTest
@testable import Kero

@MainActor
final class KeroMobileTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KeroMobileTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        keychain = KeychainStore(
            service: "sh.kero.mobile.tests.\(UUID().uuidString)"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        keychain = nil
    }

    func testSoftwareKeyboardReturnEscapesBracketedPaste() {
        let pasteStart = Data("\u{1B}[200~".utf8)
        let pasteEnd = Data("\u{1B}[201~".utf8)
        var normalizer = SSHPTYInputNormalizer()

        XCTAssertNil(normalizer.process(pasteStart))
        XCTAssertNil(normalizer.process(Data([0x0A])))
        XCTAssertEqual(normalizer.process(pasteEnd), Data([0x0D]))
    }

    func testMultilinePasteRemainsBracketed() {
        let pasteStart = Data("\u{1B}[200~".utf8)
        let pasteEnd = Data("\u{1B}[201~".utf8)
        let payload = Data("printf one\nprintf two".utf8)
        var normalizer = SSHPTYInputNormalizer()

        XCTAssertNil(normalizer.process(pasteStart))
        XCTAssertNil(normalizer.process(payload))

        var expected = pasteStart
        expected.append(payload)
        expected.append(pasteEnd)
        XCTAssertEqual(normalizer.process(pasteEnd), expected)
    }

    func testHostnameNormalizationAndIPv6Display() {
        XCTAssertEqual(
            SSHHost.normalizeHostnameInput("  [2001:db8::1]  "),
            "2001:db8::1"
        )
        XCTAssertTrue(SSHHost.isValidHostname("server.example.com"))
        XCTAssertFalse(SSHHost.isValidHostname("bad host"))

        let host = SSHHost(
            name: "",
            hostname: "2001:db8::1",
            port: 2222,
            username: "demo"
        )
        XCTAssertEqual(host.endpoint, "[2001:db8::1]:2222")
        XCTAssertEqual(host.normalizedEndpoint, "[2001:db8::1]:2222")
    }

    func testTerminalUsesBundledJetBrainsMono() {
        XCTAssertTrue(MobileTerminalFont.registerBundledFonts())

        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        XCTAssertTrue(
            terminalView.renderedTerminalConfiguration.contains(
                "font-family = JetBrains Mono"
            )
        )

        terminalView.setFontSize(17)
        XCTAssertTrue(
            terminalView.renderedTerminalConfiguration.contains(
                "font-size = 17"
            )
        )
        XCTAssertEqual(terminalView.configuredFontSize, 17, accuracy: 0.01)
    }

    func testRemoteGitPorcelainParser() {
        let records = [
            "# branch.oid 751864f616a4563d5e0abcc9b52f1f530c0f18e2",
            "# branch.head feature/files",
            "# branch.upstream origin/feature/files",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 abc def README.md",
            "1 .M N... 100644 100644 100644 abc def Sources/App.swift",
            "2 R. N... 100644 100644 100644 abc def R100 Sources/New.swift",
            "Sources/Old.swift",
            "? Notes.md",
        ]
        let data = Data(
            (records.joined(separator: "\0") + "\0").utf8
        )

        let snapshot = RemoteProjectModel.parseGitStatus(
            data,
            repositoryRoot: "/srv/kero"
        )

        XCTAssertEqual(snapshot.branch, "feature/files")
        XCTAssertEqual(
            snapshot.headOID,
            "751864f616a4563d5e0abcc9b52f1f530c0f18e2"
        )
        XCTAssertTrue(snapshot.hasHead)
        XCTAssertEqual(snapshot.upstream, "origin/feature/files")
        XCTAssertEqual(snapshot.ahead, 2)
        XCTAssertEqual(snapshot.behind, 1)
        XCTAssertEqual(snapshot.entries.map(\.path), [
            "Notes.md",
            "README.md",
            "Sources/App.swift",
            "Sources/New.swift",
        ])
        XCTAssertEqual(snapshot.staged.map(\.path), [
            "README.md",
            "Sources/New.swift",
        ])
        XCTAssertEqual(
            snapshot.entries.last?.originalPath,
            "Sources/Old.swift"
        )
        XCTAssertEqual(snapshot.changed.map(\.path), [
            "Notes.md",
            "Sources/App.swift",
        ])
    }

    func testRemoteGitRepositoryDetailsParser() {
        let snapshot = RemoteGitSnapshot(
            repositoryRoot: "/srv/kero",
            branch: "feature/mobile",
            headOID: "abcdef",
            upstream: "origin/feature/mobile",
            ahead: 1,
            behind: 2,
            entries: []
        )
        let details = """
        B\tmain
        B\tfeature/mobile
        R\torigin
        C\tabcdef\tabcdef0\t1775011200\tEgoist\tImprove Source Control
        S\t2
        O\tRebasing

        """

        let parsed = RemoteProjectModel.parseRepositoryDetails(
            Data(details.utf8),
            snapshot: snapshot
        )

        XCTAssertEqual(parsed.branches, ["feature/mobile", "main"])
        XCTAssertEqual(parsed.remotes, ["origin"])
        XCTAssertEqual(parsed.recentCommits.first?.shortHash, "abcdef0")
        XCTAssertEqual(
            parsed.recentCommits.first?.subject,
            "Improve Source Control"
        )
        XCTAssertEqual(parsed.stashCount, 2)
        XCTAssertEqual(parsed.repositoryOperation, "Rebasing")
    }

    func testRemoteGitCommitKeepsStagedOnlyAsTheDefault() async {
        let recorder = GitCommandRecorder()
        let project = RemoteProjectModel { command in
            recorder.commands.append(command)
            return recorder.result(for: command)
        }
        project.setWorkingDirectory("/srv/kero")
        await project.refreshGit()

        let success = await project.commit(
            message: "Ship mobile source control",
            includeAll: false
        )

        XCTAssertTrue(success)
        XCTAssertTrue(
            recorder.commands.contains {
                $0.contains("git -C '/srv/kero' commit -m ")
            }
        )
        XCTAssertFalse(
            recorder.commands.contains {
                $0.contains("git -C '/srv/kero' add -A")
            }
        )
        XCTAssertTrue(
            recorder.commands
                .filter { $0.contains("git -C '/srv/kero'") }
                .allSatisfy {
                    $0.hasPrefix(
                        "env LC_ALL=C GIT_TERMINAL_PROMPT=0 "
                    )
                        || $0.hasPrefix("git -C ")
                }
        )
    }

    func testRemoteGitStageAllCommitAndSyncAreExplicit() async {
        let recorder = GitCommandRecorder()
        let project = RemoteProjectModel { command in
            recorder.commands.append(command)
            return recorder.result(for: command)
        }
        project.setWorkingDirectory("/srv/kero")
        await project.refreshGit()

        let committed = await project.commit(
            message: "Commit everything",
            includeAll: true
        )
        XCTAssertTrue(committed)
        XCTAssertTrue(
            recorder.commands.contains {
                $0.contains("git -C '/srv/kero' add -A")
            }
        )

        recorder.commands.removeAll()
        let synced = await project.syncChanges()
        XCTAssertTrue(synced)
        let syncCommands = recorder.commands.filter {
            $0.contains("git -C '/srv/kero' pull --ff-only")
                || $0.contains("git -C '/srv/kero' push")
        }
        XCTAssertEqual(syncCommands.count, 2)
        XCTAssertTrue(syncCommands[0].contains("pull --ff-only"))
        XCTAssertTrue(syncCommands[1].hasSuffix(" push"))
    }

    func testRemoteGitDiscardIsPathScoped() async throws {
        let recorder = GitCommandRecorder()
        let project = RemoteProjectModel { command in
            recorder.commands.append(command)
            return recorder.result(for: command)
        }
        project.setWorkingDirectory("/srv/kero")
        await project.refreshGit()

        let untracked = RemoteGitEntry(
            path: "Notes from O'Brien.txt",
            stagedStatus: "?",
            worktreeStatus: "."
        )
        let discarded = await project.discard(untracked)
        XCTAssertTrue(discarded)

        let clean = try XCTUnwrap(
            recorder.commands.first {
                $0.contains(" clean -f -- ")
            }
        )
        XCTAssertTrue(clean.contains("--literal-pathspecs clean -f --"))
        XCTAssertTrue(clean.contains("'Notes from O'\\''Brien.txt'"))
        XCTAssertFalse(clean.contains("clean -fd"))
    }

    func testRemoteFilesRunPOSIXListingThroughExplicitShell() async {
        var commands: [String] = []
        let project = RemoteProjectModel { command in
            commands.append(command)
            if command.hasPrefix("git -C ") {
                return SSHCommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitStatus: 1
                )
            }
            return SSHCommandResult(
                stdout: Data("d\0Sources\0f\0README.md\0".utf8),
                stderr: Data(),
                exitStatus: 0
            )
        }

        project.setWorkingDirectory("/Users/o'brien")
        await project.refreshFiles()

        XCTAssertEqual(project.files.map(\.name), ["Sources", "README.md"])
        guard let listing = commands.last else {
            return XCTFail("The remote directory listing was not requested.")
        }
        XCTAssertTrue(listing.hasPrefix("/bin/sh -c "))
        XCTAssertTrue(listing.contains("dir=$1"))
        XCTAssertTrue(listing.hasSuffix(" sh '/Users/o'\\''brien'"))
        XCTAssertFalse(listing.hasPrefix("dir="))
    }

    func testRemoteGitRepositoryCanBeInitialized() async {
        var commands: [String] = []
        var initialized = false
        let project = RemoteProjectModel { command in
            commands.append(command)
            if command.contains("rev-parse --show-toplevel") {
                return SSHCommandResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitStatus: 128
                )
            }
            if command.hasSuffix(" init") {
                initialized = true
                return SSHCommandResult(
                    stdout: Data(
                        "Initialized empty Git repository\n".utf8
                    ),
                    stderr: Data(),
                    exitStatus: 0
                )
            }
            if command.contains("status --porcelain=v2") {
                if !initialized {
                    return SSHCommandResult(
                        stdout: Data(),
                        stderr: Data(
                            "fatal: not a git repository\n".utf8
                        ),
                        exitStatus: 128
                    )
                }
                return SSHCommandResult(
                    stdout: Data(
                        "# branch.oid (initial)\0"
                            .appending("# branch.head main\0")
                            .appending("? README.md\0")
                            .utf8
                    ),
                    stderr: Data(),
                    exitStatus: 0
                )
            }
            return SSHCommandResult(
                stdout: Data(),
                stderr: Data(),
                exitStatus: 1
            )
        }

        project.setWorkingDirectory("/Users/builder/project")
        await project.refreshGit()

        XCTAssertTrue(project.hasLoadedGit)
        XCTAssertTrue(project.canInitializeGit)
        XCTAssertNil(project.git)
        XCTAssertNil(project.gitError)

        await project.initializeRepository()

        XCTAssertFalse(project.canInitializeGit)
        XCTAssertEqual(project.git?.branch, "main")
        XCTAssertEqual(project.git?.changed.map(\.path), ["README.md"])
        XCTAssertTrue(
            commands.contains {
                $0.contains(
                    "git -C '/Users/builder/project' init"
                )
            }
        )
    }

    func testKnownHostsPersistAndDetectChangedKeys() throws {
        let url = temporaryDirectory.appendingPathComponent("known-hosts.json")
        let store = KnownHostStore(storageURL: url)
        let host = SSHHost(
            name: "Test",
            hostname: "server.example.com",
            username: "demo"
        )

        let firstKey = "ssh-ed25519 AQID"
        let secondKey = "ssh-ed25519 BAUG"

        guard case .unknown(let proposed) = store.evaluate(
            host: host,
            openSSHKey: firstKey
        ) else {
            return XCTFail("A new server must require explicit trust.")
        }
        XCTAssertTrue(proposed.fingerprint.hasPrefix("SHA256:"))
        try store.trust(proposed)

        guard case .trusted = store.evaluate(
            host: host,
            openSSHKey: firstKey
        ) else {
            return XCTFail("The exact saved key should be trusted.")
        }

        let reloaded = KnownHostStore(storageURL: url)
        guard case .changed(let existing, let replacement) = reloaded.evaluate(
            host: host,
            openSSHKey: secondKey
        ) else {
            return XCTFail("A changed server key must never be trusted silently.")
        }
        XCTAssertEqual(existing.fingerprint, proposed.fingerprint)
        XCTAssertNotEqual(replacement.fingerprint, proposed.fingerprint)

        try reloaded.deleteAll()
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    func testPasswordsStayOutOfHostMetadata() async throws {
        let url = temporaryDirectory.appendingPathComponent("hosts.json")
        let store = HostStore(storageURL: url, keychain: keychain)
        let host = SSHHost(
            name: "Production",
            hostname: "prod.example.com",
            username: "deploy"
        )

        try store.upsert(host, password: "very-secret-value")
        XCTAssertEqual(try store.password(for: host), "very-secret-value")
        let connectionPassword = try await store.passwordForConnection(for: host)
        XCTAssertEqual(connectionPassword, "very-secret-value")

        let metadata = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(metadata.contains("very-secret-value"))
        XCTAssertTrue(metadata.contains("prod.example.com"))

        var editedHost = host
        editedHost.name = "Production Renamed"
        try store.upsert(editedHost, password: nil)
        XCTAssertEqual(try store.password(for: editedHost), "very-secret-value")

        try store.upsert(editedHost, password: "replacement-secret")
        XCTAssertEqual(try store.password(for: editedHost), "replacement-secret")

        editedHost.authentication = .identity
        editedHost.identityID = UUID()
        try store.upsert(editedHost, password: nil)
        XCTAssertThrowsError(try store.password(for: editedHost))

        try store.deleteAll()
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertThrowsError(try store.password(for: host))
    }

    func testGeneratedIdentityCanBeRecoveredAndErased() throws {
        let url = temporaryDirectory.appendingPathComponent("identities.json")
        let store = IdentityStore(storageURL: url, keychain: keychain)
        let identity = try store.generate(
            name: "Release Test",
            requiresUserPresence: false
        )

        XCTAssertTrue(identity.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(identity.fingerprint.hasPrefix("SHA256:"))
        _ = try store.privateKey(
            for: identity.id,
            hostName: "Test Server"
        )

        let reloaded = IdentityStore(storageURL: url, keychain: keychain)
        XCTAssertEqual(reloaded.identities, [identity])

        try reloaded.deleteAll()
        XCTAssertTrue(reloaded.identities.isEmpty)
        XCTAssertThrowsError(
            try reloaded.privateKey(
                for: identity.id,
                hostName: "Test Server"
            )
        )
    }

    func testSessionStoreReusesSessionUntilExplicitlyClosed() {
        let hostStore = HostStore(
            storageURL: temporaryDirectory.appendingPathComponent("hosts.json"),
            keychain: keychain
        )
        let identityStore = IdentityStore(
            storageURL: temporaryDirectory.appendingPathComponent(
                "identities.json"
            ),
            keychain: keychain
        )
        let knownHostStore = KnownHostStore(
            storageURL: temporaryDirectory.appendingPathComponent(
                "known-hosts.json"
            )
        )
        let sessionStore = TerminalSessionStore(
            hostStore: hostStore,
            identityStore: identityStore,
            knownHostStore: knownHostStore
        )
        let host = SSHHost(
            name: "Persistent Session",
            hostname: "server.example.com",
            username: "demo"
        )

        let first = sessionStore.openSession(for: host)
        let second = sessionStore.openSession(for: host)

        XCTAssertTrue(first === second)
        XCTAssertEqual(sessionStore.sessions.count, 1)
        XCTAssertTrue(first.terminalView === second.terminalView)

        sessionStore.close(first)

        XCTAssertTrue(sessionStore.sessions.isEmpty)
        let replacement = sessionStore.openSession(for: host)
        XCTAssertFalse(first === replacement)
    }

    func testPasswordSSHHandshakeShellInputAndResize() async throws {
        let server = TestSSHServer()
        try server.start()
        defer {
            try? server.stop()
        }

        let hostKeyReceived = expectation(
            description: "Server host key was offered for validation"
        )
        let connected = expectation(
            description: "SSH shell became ready"
        )
        let inputReceived = expectation(
            description: "Shell received terminal input"
        )
        let resizeReceived = expectation(
            description: "Shell received the requested terminal size"
        )
        let commandReceived = expectation(
            description: "Exec channel received a remote command"
        )
        let disconnected = expectation(
            description: "SSH client disconnected cleanly"
        )

        server.onInput = { data in
            guard data == Data([0x0D]) else {
                return
            }
            inputReceived.fulfill()
        }
        server.onResize = { request in
            guard request.terminalCharacterWidth == 101,
                  request.terminalRowHeight == 41,
                  request.terminalPixelWidth == 1_170,
                  request.terminalPixelHeight == 2_100 else {
                return
            }
            resizeReceived.fulfill()
        }
        server.onExec = { command in
            commandReceived.fulfill()
            return TestSSHCommandResponse(
                stdout: "executed:\(command)\n",
                stderr: "command-warning\n",
                exitStatus: 7
            )
        }

        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let window = UIWindow(frame: terminalView.frame)
        let viewController = UIViewController()
        window.rootViewController = viewController
        viewController.view.addSubview(terminalView)
        window.makeKeyAndVisible()
        terminalView.fitToSize()
        defer {
            terminalView.removeFromSuperview()
            window.isHidden = true
        }
        let host = SSHHost(
            name: "Integration Server",
            hostname: "127.0.0.1",
            port: server.port,
            username: "release"
        )
        let configuration = SSHConnectionConfiguration(
            host: host,
            credential: .password("integration-secret"),
            term: "xterm-256color",
            environment: ["LANG": "en_US.UTF-8"],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )

        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { key, completion in
                XCTAssertTrue(key.hasPrefix("ssh-ed25519 "))
                hostKeyReceived.fulfill()
                completion(true)
            },
            onStateChange: { state in
                switch state {
                case .connected:
                    connected.fulfill()
                case .disconnected:
                    disconnected.fulfill()
                case .failed(let message):
                    XCTFail("Integration SSH connection failed: \(message)")
                default:
                    break
                }
            }
        )

        terminalView.attachConnection(connection)
        connection.connect()
        await fulfillment(
            of: [hostKeyReceived, connected],
            timeout: 8
        )

        let commandResult = try await withCheckedThrowingContinuation {
            continuation in
            connection.execute(command: "pwd -P") {
                continuation.resume(with: $0)
            }
        }
        XCTAssertEqual(commandResult.stdoutString, "executed:pwd -P\n")
        XCTAssertEqual(commandResult.stderrString, "command-warning\n")
        XCTAssertEqual(commandResult.exitStatus, 7)

        // Exercise the protocol witness used by UIKit's software keyboard,
        // not a direct subclass call.
        let softwareKeyboard: any UIKeyInput = terminalView
        for character in "release-check" {
            softwareKeyboard.insertText(String(character))
        }
        softwareKeyboard.insertText("\n")
        connection.resize(
            SSHWindowSize(
                columns: 101,
                rows: 41,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        await fulfillment(
            of: [commandReceived, inputReceived, resizeReceived],
            timeout: 5
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(
            terminalView.viewportText().contains("Kero integration shell")
        )

        connection.disconnect()
        terminalView.detachConnection(connection)
        await fulfillment(of: [disconnected], timeout: 5)
    }

    func testRejectedPasswordReportsAuthenticationFailure() async throws {
        let server = TestSSHServer()
        try server.start()
        defer {
            try? server.stop()
        }

        let failed = expectation(
            description: "Rejected password produced a useful failure"
        )
        var failureMessage: String?
        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let configuration = SSHConnectionConfiguration(
            host: SSHHost(
                name: "Rejected Password Server",
                hostname: "127.0.0.1",
                port: server.port,
                username: "release"
            ),
            credential: .password("incorrect-password"),
            term: "xterm-256color",
            environment: [:],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { _, completion in
                completion(true)
            },
            onStateChange: { state in
                switch state {
                case .failed(let message):
                    failureMessage = message
                    failed.fulfill()
                case .connected:
                    XCTFail("A rejected password must not connect.")
                default:
                    break
                }
            }
        )

        connection.connect()
        await fulfillment(of: [failed], timeout: 8)
        XCTAssertEqual(
            failureMessage,
            "Authentication failed. Check the username and password or SSH key."
        )
    }

    func testSilentServerReportsHandshakeTimeout() async throws {
        let server = TestSilentTCPServer()
        try server.start()
        defer {
            try? server.stop()
        }

        let failed = expectation(
            description: "Silent server produced a handshake timeout"
        )
        var failureMessage: String?
        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let configuration = SSHConnectionConfiguration(
            host: SSHHost(
                name: "Silent Server",
                hostname: "127.0.0.1",
                port: server.port,
                username: "release"
            ),
            credential: .password("integration-secret"),
            term: "xterm-256color",
            environment: [:],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { _, completion in
                completion(true)
            },
            connectionTimeout: .milliseconds(250),
            onStateChange: { state in
                guard case .failed(let message) = state else {
                    return
                }
                failureMessage = message
                failed.fulfill()
            }
        )

        connection.connect()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(
            failureMessage,
            "The SSH handshake timed out. Check the server address, network access, and authentication settings."
        )
    }

    func testEd25519SSHAuthentication() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let privateKey = NIOSSHPrivateKey(ed25519Key: signingKey)
        let server = TestSSHServer(
            authentication: .publicKey(
                username: "release",
                key: privateKey.publicKey
            )
        )
        try server.start()
        defer {
            try? server.stop()
        }

        let connected = expectation(
            description: "Ed25519-authenticated shell became ready"
        )
        let disconnected = expectation(
            description: "Ed25519 SSH client disconnected cleanly"
        )

        let terminalView = KeroTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700)
        )
        let configuration = SSHConnectionConfiguration(
            host: SSHHost(
                name: "Key Server",
                hostname: "127.0.0.1",
                port: server.port,
                username: "release",
                authentication: .identity
            ),
            credential: .privateKey(privateKey),
            term: "xterm-256color",
            environment: [:],
            initialSize: SSHWindowSize(
                columns: 80,
                rows: 24,
                pixelWidth: 1_170,
                pixelHeight: 2_100
            )
        )
        let connection = SSHConnection(
            terminalView: terminalView,
            configuration: configuration,
            validateHostKey: { _, completion in
                completion(true)
            },
            onStateChange: { state in
                switch state {
                case .connected:
                    connected.fulfill()
                case .disconnected:
                    disconnected.fulfill()
                case .failed(let message):
                    XCTFail("Ed25519 SSH connection failed: \(message)")
                default:
                    break
                }
            }
        )

        connection.connect()
        await fulfillment(of: [connected], timeout: 8)
        connection.disconnect()
        await fulfillment(of: [disconnected], timeout: 5)
    }
}

@MainActor
private final class GitCommandRecorder {
    var commands: [String] = []

    func result(for command: String) -> SSHCommandResult {
        if command.contains("rev-parse --show-toplevel") {
            return success("/srv/kero\n")
        }
        if command.contains("status --porcelain=v2") {
            return success(
                "# branch.oid abcdef\0"
                    + "# branch.head main\0"
                    + "# branch.upstream origin/main\0"
                    + "# branch.ab +1 -1\0"
                    + "1 M. N... 100644 100644 100644 abc def README.md\0"
                    + "1 .M N... 100644 100644 100644 abc def Sources/App.swift\0"
                    + "? Notes.md\0"
            )
        }
        if command.hasPrefix("/bin/sh -c ") {
            return success(
                "B\tmain\n"
                    + "R\torigin\n"
                    + "C\tabcdef\tabcdef0\t1775011200\tEgoist\tLatest work\n"
                    + "S\t1\n"
            )
        }
        return success()
    }

    private func success(_ output: String = "") -> SSHCommandResult {
        SSHCommandResult(
            stdout: Data(output.utf8),
            stderr: Data(),
            exitStatus: 0
        )
    }
}
