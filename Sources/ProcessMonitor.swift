import Foundation
import Darwin
import AppKit
import SwiftUI

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

/// One poll of `ps` plus the cheap system-health readings shown in the
/// sidebar and menu-bar panel.
struct SystemSnapshot {
    var entries: [ProcessEntry] = []
    var memoryFreePercent: Int? = nil   // from /usr/bin/memory_pressure
    var swapUsedBytes: Int64 = 0        // from sysctl vm.swapusage
    var batteryPercent: Int? = nil      // from pmset -g batt
    var batteryState: String? = nil     // "Charging" / "On Battery" / "Full"
}

/// A process-name pattern considered a dev leftover worth stopping at
/// end of day (dev servers, build watchers, local DBs, VMs).
struct DevRule {
    let match: String   // case-insensitive substring of the executable basename
    let label: String
}

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var entries: [ProcessEntry] = []
    @Published var refreshing = false
    @Published var autoRefresh = UserDefaults.standard.object(forKey: "liveMonitoring") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "liveMonitoring") }
    }
    @Published var lastRefresh: Date?
    @Published var statusMessage: String?

    // System health (updated on every refresh).
    @Published var memoryFreePercent: Int?
    @Published var swapUsedBytes: Int64 = 0
    @Published var batteryPercent: Int?
    @Published var batteryState: String?
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    // View state for the process browser.
    @Published var searchText = ""
    @Published var sortOrder: [KeyPathComparator<ProcessEntry>] = [KeyPathComparator(\.cpu, order: .reverse)]
    @Published var selectedPIDs: Set<Int32> = []
    @Published var pendingKill: PendingKill?

    // End-of-day sheet state.
    @Published var showEndOfDay = false
    @Published var eodStopDev = true
    @Published var eodQuitApps = true
    @Published var eodCleanStorage = false

    @AppStorage("refreshSeconds") var refreshSeconds = 2.0
    @Published var history: [ResourceSample] = []

    private var pollTask: Task<Void, Never>?

    var totalCPU: Double { entries.reduce(0) { $0 + $1.cpu } }
    var totalMem: Int64 { entries.reduce(0) { $0 + $1.memBytes } }

    /// Processes matching the dev-leftover rules — the "kalat" left running
    /// after a dev session.
    var devEntries: [ProcessEntry] {
        entries.filter { Self.devRule(for: $0.name) != nil }
    }

    // MARK: - Dev process rules

    static let devRules: [DevRule] = [
        DevRule(match: "node", label: "Node.js"),
        DevRule(match: "npm", label: "npm"),
        DevRule(match: "npx", label: "npx"),
        DevRule(match: "yarn", label: "Yarn"),
        DevRule(match: "pnpm", label: "pnpm"),
        DevRule(match: "bun", label: "Bun"),
        DevRule(match: "deno", label: "Deno"),
        DevRule(match: "vite", label: "Vite"),
        DevRule(match: "esbuild", label: "esbuild"),
        DevRule(match: "tsc", label: "TypeScript compiler"),
        DevRule(match: "tsx", label: "tsx"),
        DevRule(match: "metro", label: "Metro bundler"),
        DevRule(match: "watchman", label: "Watchman"),
        DevRule(match: "webpack", label: "webpack"),
        DevRule(match: "jest", label: "Jest"),
        DevRule(match: "vitest", label: "Vitest"),
        DevRule(match: "nodemon", label: "nodemon"),
        DevRule(match: "uvicorn", label: "uvicorn"),
        DevRule(match: "gunicorn", label: "gunicorn"),
        DevRule(match: "python", label: "Python"),
        DevRule(match: "ruby", label: "Ruby"),
        DevRule(match: "php", label: "PHP"),
        DevRule(match: "xcodebuild", label: "Xcode build"),
        DevRule(match: "simctl", label: "Simulator control"),
        DevRule(match: "swift-frontend", label: "Swift build"),
        DevRule(match: "swift-build", label: "Swift build"),
        DevRule(match: "simulator", label: "iOS Simulator"),
        DevRule(match: "docker", label: "Docker"),
        DevRule(match: "vpnkit", label: "Docker"),
        DevRule(match: "qemu", label: "VM"),
        DevRule(match: "orbstack", label: "OrbStack"),
        DevRule(match: "utm", label: "UTM"),
        DevRule(match: "redis", label: "Redis"),
        DevRule(match: "postgres", label: "Postgres"),
        DevRule(match: "mongod", label: "MongoDB"),
        DevRule(match: "mysql", label: "MySQL"),
        DevRule(match: "caddy", label: "Caddy"),
        DevRule(match: "nginx", label: "nginx"),
        DevRule(match: "flutter", label: "Flutter"),
    ]

    static func devRule(for name: String) -> DevRule? {
        let lower = name.lowercased()
        return devRules.first { lower.contains($0.match.lowercased()) }
    }

    // MARK: - Polling

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64((self?.refreshSeconds ?? 2) * 1_000_000_000))
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
        guard pendingKill == nil, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let snap = await Task.detached(priority: .utility) { Self.collect() }.value
        entries = snap.entries.sorted { $0.cpu > $1.cpu }
        memoryFreePercent = snap.memoryFreePercent
        swapUsedBytes = snap.swapUsedBytes
        batteryPercent = snap.batteryPercent
        batteryState = snap.batteryState
        thermalState = ProcessInfo.processInfo.thermalState
        lastRefresh = Date()
        history.append(ResourceSample(date: Date(), cpu: totalCPU, memoryGB: Double(totalMem) / 1_000_000_000))
        history.removeAll { $0.date < Date().addingTimeInterval(-600) }
        let live = Set(snap.entries.map(\.pid))
        selectedPIDs.formIntersection(live)
    }

    /// One off-main-actor snapshot: `ps` output plus health readings.
    nonisolated static func collect() -> SystemSnapshot {
        var snap = SystemSnapshot()
        snap.entries = collectProcesses()
        snap.memoryFreePercent = readMemoryFreePercent()
        snap.swapUsedBytes = readSwapUsedBytes()
        if let batt = readBatteryStatus() {
            snap.batteryPercent = batt.percent
            snap.batteryState = batt.state
        }
        return snap
    }

    /// Snapshot of every process via /bin/ps. Runs off the main actor.
    nonisolated static func collectProcesses() -> [ProcessEntry] {
        guard let text = runProcess("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="]) else { return [] }

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

    /// Run a command and return stdout as a String (nil on failure).
    nonisolated static func runProcess(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - System health

    /// "System-wide memory free percentage: NN%" from /usr/bin/memory_pressure.
    nonisolated static func readMemoryFreePercent() -> Int? {
        guard let out = runProcess("/usr/bin/memory_pressure", []),
              let r = out.range(of: "free percentage:") else { return nil }
        let digits = out[r.upperBound...]
            .drop(while: { $0 == " " || $0 == "\t" })
            .prefix(while: { $0.isNumber })
        return Int(digits)
    }

    nonisolated static func readSwapUsedBytes() -> Int64 {
        // struct xsw_usage { u_int64_t total, used; u_int32_t pagesize; boolean_t encrypted; }
        struct xsw_usage {
            var total: UInt64 = 0
            var used: UInt64 = 0
            var pageSize: UInt32 = 0
            var encrypted: Int32 = 0
        }
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &len, nil, 0) == 0 else { return 0 }
        return Int64(usage.used)
    }

    /// Battery percent + coarse state from `pmset -g batt`.
    nonisolated static func readBatteryStatus() -> (percent: Int, state: String?)? {
        guard let out = runProcess("/bin/pmset", ["-g", "batt"]) else { return nil }
        for line in out.split(separator: "\n") {
            guard let m = line.range(of: #"\d+%"#, options: .regularExpression) else { continue }
            guard let pct = Int(line[m].dropLast()) else { continue }
            let lower = line.lowercased()
            let state: String?
            if lower.contains("discharging") { state = "On Battery" }
            else if lower.contains("charging") { state = "Charging" }
            else if lower.contains("charged") { state = "Full" }
            else { state = nil }
            return (pct, state)
        }
        return nil
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

    /// SIGTERM every currently-selected process (multi-select kill).
    func terminateSelected() {
        let targets = entries.filter { selectedPIDs.contains($0.pid) }
        guard !targets.isEmpty else { return }
        for t in targets { _ = Self.signal(t.pid, force: false) }
        statusMessage = "Sent SIGTERM to \(targets.count) process\(targets.count == 1 ? "" : "es")."
        selectedPIDs = []
        Task { await refresh() }
    }

    /// One-click dev cleanup: SIGTERM every dev-leftover process.
    /// Our own pid is never signaled.
    @discardableResult
    func stopAllDev(force: Bool = false) -> Int {
        let me = ProcessInfo.processInfo.processIdentifier
        let targets = devEntries.filter { $0.pid != me }
        guard !targets.isEmpty else {
            statusMessage = "No dev processes running."
            return 0
        }
        var ok = 0
        for t in targets where Self.signal(t.pid, force: force) == nil { ok += 1 }
        statusMessage = "Sent SIG\(force ? "KILL" : "TERM") to \(ok) dev process\(ok == 1 ? "" : "es")."
        Task { await refresh() }
        return ok
    }

    /// Gracefully quit every regular (non-Apple, non-self) app — the
    /// "tapusin ang buka" part of end-of-day. Returns apps asked to quit.
    @discardableResult
    static func quitOtherApps() -> Int {
        let me = ProcessInfo.processInfo.processIdentifier
        var count = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.processIdentifier == me { continue }
            if app.bundleIdentifier == "com.apple.finder" { continue }
            if let url = app.bundleURL, url.path.hasPrefix("/System/") { continue }
            if app.terminate() { count += 1 }
        }
        return count
    }

    /// Returns nil on success, otherwise a human-readable reason.
    nonisolated static func signal(_ pid: Int32, force: Bool) -> String? {
        let sig: Int32 = force ? SIGKILL : SIGTERM
        if Darwin.kill(pid, sig) == 0 { return nil }
        let code = errno
        return "Could not signal pid \(pid) (\(String(cString: strerror(code)))) — system processes are protected."
    }
}
