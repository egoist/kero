//
//  SessionInfoModel.swift
//  kero
//

import Combine
import Darwin
import Foundation

/// Polls `ps`/`lsof` for the active session's shell: the processes running
/// under it and any TCP ports those processes are listening on.
@MainActor
final class SessionInfoModel: nonisolated ObservableObject {
    struct ProcessItem: Identifiable, Equatable {
        var id: pid_t { pid }
        let pid: pid_t
        /// Executable name, e.g. "node".
        let name: String
        /// Full executable path, for tooltips.
        let executable: String
        /// Percent CPU as `ps` reports it.
        let cpu: Double
        /// Resident set size in kilobytes.
        let memoryKB: Int

        var memoryLabel: String {
            ByteCountFormatter.string(
                fromByteCount: Int64(memoryKB) * 1024,
                countStyle: .memory
            )
        }
    }

    struct PortItem: Identifiable, Equatable {
        var id: String { "\(pid):\(port)" }
        let port: Int
        let pid: pid_t
        let processName: String

        var url: URL? { URL(string: "http://localhost:\(port)/") }
    }

    @Published private(set) var rootPath = ""
    /// The project directory the file tree and git panels anchor to —
    /// shown alongside the live cwd so both are visible at a glance.
    @Published private(set) var projectRootPath = ""
    /// Which rule produced that directory — pinned, the shell's repository,
    /// or the repository the foreground job moved to.
    @Published private(set) var projectRootSource = Project.PanelRootSource.shell
    @Published private(set) var shellName = ""
    @Published private(set) var shellPid: pid_t = 0
    @Published private(set) var processes: [ProcessItem] = []
    @Published private(set) var ports: [PortItem] = []

    private var isRefreshing = false

    func sync(
        root: String,
        projectRoot: String,
        projectRootSource: Project.PanelRootSource,
        shellName: String,
        shellPid: pid_t?
    ) {
        if rootPath != root { rootPath = root }
        if projectRootPath != projectRoot { projectRootPath = projectRoot }
        if self.projectRootSource != projectRootSource {
            self.projectRootSource = projectRootSource
        }
        if self.shellName != shellName { self.shellName = shellName }
        let pid = shellPid ?? 0
        if self.shellPid != pid { self.shellPid = pid }
        refresh()
    }

    func refresh() {
        let pid = shellPid
        guard pid > 0 else {
            if !processes.isEmpty { processes = [] }
            if !ports.isEmpty { ports = [] }
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true

        Task.detached(priority: .utility) { [weak self] in
            let (processes, ports) = Self.snapshot(shellPid: pid)
            await MainActor.run {
                guard let self else { return }
                self.isRefreshing = false
                // A tab switch may have re-targeted us while ps/lsof ran.
                guard self.shellPid == pid else { return }
                if self.processes != processes { self.processes = processes }
                if self.ports != ports { self.ports = ports }
            }
        }
    }

    /// SIGTERM (or SIGKILL when `force`), then a delayed re-poll so the
    /// row disappears once the process is actually gone.
    func kill(_ pid: pid_t, force: Bool = false) {
        Darwin.kill(pid, force ? SIGKILL : SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Polling

    private nonisolated static func snapshot(
        shellPid: pid_t
    ) -> ([ProcessItem], [PortItem]) {
        // `comm` is the executable path with no arguments, so the only
        // free-form field is the last one and column parsing stays safe.
        let psOut = run("/bin/ps", ["-axo", "pid=,ppid=,stat=,pcpu=,rss=,comm="])
        var itemsByPid: [pid_t: ProcessItem] = [:]
        var childPids: [pid_t: [pid_t]] = [:]
        for line in psOut.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            // Recorded before the zombie check so the descendant walk below
            // still traverses the tree through anything we skip.
            childPids[ppid, default: []].append(pid)
            // Zombies are children that already exited and are waiting to be
            // reaped: `ps` names them "<defunct>", they hold no CPU or memory,
            // and no signal can touch them. Nothing to show or act on.
            guard !fields[2].hasPrefix("Z") else { continue }
            let executable = String(fields[5])
            itemsByPid[pid] = ProcessItem(
                pid: pid,
                name: (executable as NSString).lastPathComponent,
                executable: executable,
                cpu: Double(fields[3]) ?? 0,
                memoryKB: Int(fields[4]) ?? 0
            )
        }

        // Descendants breadth-first: the commands the user ran come before
        // the workers they spawned.
        var processes: [ProcessItem] = []
        var queue = childPids[shellPid] ?? []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            if let item = itemsByPid[pid] {
                processes.append(item)
            }
            queue.append(contentsOf: childPids[pid] ?? [])
        }

        let ports = listeningPorts(
            pids: [shellPid] + processes.map(\.pid),
            itemsByPid: itemsByPid
        )
        return (processes, ports)
    }

    private nonisolated static func listeningPorts(
        pids: [pid_t], itemsByPid: [pid_t: ProcessItem]
    ) -> [PortItem] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        // -a ANDs the selectors, so this only inspects the session's own
        // processes instead of walking every fd on the machine.
        let out = run(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", list, "-Fpn"]
        )

        var ports: [PortItem] = []
        var seen = Set<String>()
        var currentPid: pid_t = 0
        for line in out.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                currentPid = pid_t(value) ?? 0
            case "n":
                // Addresses look like "*:3000", "127.0.0.1:3000", "[::1]:3000".
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let item = PortItem(
                    port: port,
                    pid: currentPid,
                    processName: itemsByPid[currentPid]?.name ?? "?"
                )
                // The same socket shows once for IPv4 and once for IPv6.
                if seen.insert(item.id).inserted {
                    ports.append(item)
                }
            default:
                break
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    private nonisolated static func run(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
