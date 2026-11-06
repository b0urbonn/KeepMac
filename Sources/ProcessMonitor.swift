import Foundation
import Darwin

struct ProcessEntry: Identifiable, Hashable {
    let pid: Int32
    let name: String       // last path component of the executable
    let path: String       // full executable path
    let cpu: Double        // %CPU (decaying average reported by ps)
    let memBytes: Int64    // resident memory
    var id: Int32 { pid }
}

struct PendingKill: Identifiable {
    let entry: ProcessEntry
    let force: Bool        // SIGKILL instead of SIGTERM
    var id: Int32 { entry.pid }
}

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var entries: [ProcessEntry] = []
    @Published var refreshing = false
    @Published var autoRefresh = true
    @Published var lastRefresh: Date?
    @Published var statusMessage: String?

    // View state for the process browser.
    @Published var searchText = ""
    @Published var sortOrder: [KeyPathComparator<ProcessEntry>] = [KeyPathComparator(\.cpu, order: .reverse)]
    @Published var selectedPID: Int32?
    @Published var pendingKill: PendingKill?

    private var pollTask: Task<Void, Never>?

    var totalCPU: Double { entries.reduce(0) { $0 + $1.cpu } }
    var totalMem: Int64 { entries.reduce(0) { $0 + $1.memBytes } }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        // Don't churn the table while the kill-confirmation alert is up —
        // reloading rows under a modal is what triggers NSTableView
        // reentrancy warnings.
        guard pendingKill == nil else { return }
        refreshing = true
        defer { refreshing = false }
        let result = await Task.detached(priority: .utility) { Self.collect() }.value
        entries = result.sorted { $0.cpu > $1.cpu }
        lastRefresh = Date()
        if let sel = selectedPID, !result.contains(where: { $0.pid == sel }) {
            selectedPID = nil
        }
    }

    /// Snapshot of every process via /bin/ps. Runs off the main actor.
    nonisolated static func collect() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var out: [ProcessEntry] = []
        out.reserveCapacity(640)
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // pid pcpu rss comm — comm is a path that may itself contain spaces.
            let fields = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Int64(fields[2]) else { continue }
            let path = String(fields[3])
            let base = (path as NSString).lastPathComponent
            out.append(ProcessEntry(pid: pid,
                                    name: base.isEmpty ? path : base,
                                    path: path,
                                    cpu: cpu,
                                    memBytes: rssKB * 1024))
        }
        return out
    }

    // MARK: - Killing

    func requestKill(_ entry: ProcessEntry, force: Bool = false) {
        pendingKill = PendingKill(entry: entry, force: force)
    }

    func cancelKill() { pendingKill = nil }

    func confirmKill() {
        guard let kill = pendingKill else { return }
        pendingKill = nil
        if let error = Self.signal(kill.entry.pid, force: kill.force) {
            statusMessage = error
        } else {
            statusMessage = "Sent \(kill.force ? "SIGKILL" : "SIGTERM") to \(kill.entry.name) (pid \(kill.entry.pid))"
        }
        Task { await refresh() }
    }

    /// Returns nil on success, otherwise a human-readable reason.
    nonisolated static func signal(_ pid: Int32, force: Bool) -> String? {
        let sig: Int32 = force ? SIGKILL : SIGTERM
        if Darwin.kill(pid, sig) == 0 { return nil }
        let code = errno
        return "Could not signal pid \(pid) (\(String(cString: strerror(code)))) — system processes are protected."
    }
}
