import SwiftUI

// MARK: - Process monitor detail view

struct ProcessDetailView: View {
    @EnvironmentObject var monitor: ProcessMonitor

    private var shown: [ProcessEntry] {
        var list = monitor.entries
        let q = monitor.searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.path.localizedCaseInsensitiveContains(q)
            }
        }
        return list.sorted(using: monitor.sortOrder)
    }

    private var selectedEntries: [ProcessEntry] {
        monitor.entries.filter { monitor.selectedPIDs.contains($0.pid) }
    }

    private var selected: ProcessEntry? { selectedEntries.first }

    var body: some View {
        VStack(spacing: 0) {
            ProcHeader().padding(.top, 10)
            ProcStatsBar().padding(.top, 12)
            VStack(spacing: 0) {
                ProcBrowserBar(count: shown.count).padding(.vertical, 10)
                Divider()
                Group {
                    if shown.isEmpty {
                        if monitor.entries.isEmpty {
                            ProgressView("Reading processes…")
                        } else {
                            ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                description: Text("Nothing matches “\(monitor.searchText)”."))
                        }
                    } else {
                        ProcTable(items: shown)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if selected != nil {
                    Divider()
                    ProcInspector().frame(height: 118)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)) }
            .padding(.horizontal, 24).padding(.bottom, 12)
            ProcCleanupBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await monitor.refresh()
            if monitor.autoRefresh { monitor.start() } else { monitor.stop() }
        }
        .onChange(of: monitor.autoRefresh) { _, on in on ? monitor.start() : monitor.stop() }
        .alert("Terminate process?",
               isPresented: Binding(
                get: { monitor.pendingKill != nil },
                set: { if !$0 { monitor.cancelKill() } }
               )) {
            if let kill = monitor.pendingKill {
                Button(kill.force ? "Force Quit" : "Terminate", role: .destructive) {
                    monitor.confirmKill()
                }
            }
            Button("Cancel", role: .cancel) { monitor.cancelKill() }
        } message: {
            if let kill = monitor.pendingKill {
                Text("Send \(kill.force ? "SIGKILL" : "SIGTERM") to \(kill.entry.name) (pid \(kill.entry.pid))? Unsaved work may be lost.")
            }
        }
    }
}

// MARK: - Header

struct ProcHeader: View {
    @EnvironmentObject var monitor: ProcessMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Process workspace")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("Inspect CPU, memory, and developer workloads. Review processes before terminating them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Inspect CPU, memory, and developer workloads. Review processes before terminating them.")
            }
            Spacer(minLength: 0)
            if monitor.refreshing {
                ProgressView().controlSize(.small).padding(.top, 7)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Stats bar

struct ProcStatsBar: View {
    @EnvironmentObject var monitor: ProcessMonitor

    private var uptimeText: String {
        let secs = Int(ProcessInfo.processInfo.systemUptime)
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var body: some View {
        HStack(spacing: 0) {
            stat("CPU usage", value: String(format: "%.0f%%", monitor.totalCPU), icon: "cpu")
            Divider().frame(height: 28)
            stat("Process memory", value: monitor.totalMem.bytesFormatted, icon: "memorychip")
            Divider().frame(height: 28)
            stat("Processes", value: "\(monitor.entries.count)", icon: "square.stack.3d.up")
            Divider().frame(height: 28)
            stat("Uptime", value: uptimeText, icon: "clock")
            Spacer(minLength: 0)
            if let t = monitor.lastRefresh {
                Text("Updated \(t, style: .relative) ago")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)) }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private func stat(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tint).font(.callout)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }
}

// MARK: - Browser bar

struct ProcBrowserBar: View {
    @EnvironmentObject var monitor: ProcessMonitor
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) \(count == 1 ? "process" : "processes")")
                .font(.headline).monospacedDigit()
            Spacer(minLength: 8)
            Toggle("Auto-refresh", isOn: $monitor.autoRefresh)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Refresh the process list every 2 seconds")
            Button { Task { await monitor.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(monitor.refreshing)
            .help("Refresh now")
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter name or path", text: $monitor.searchText)
                    .textFieldStyle(.plain)
                if !monitor.searchText.isEmpty {
                    Button { monitor.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            .frame(width: 220)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
    }
}

// MARK: - Process table

struct ProcTable: View {
    @EnvironmentObject var monitor: ProcessMonitor
    let items: [ProcessEntry]

    var body: some View {
        Table(items, selection: $monitor.selectedPIDs, sortOrder: $monitor.sortOrder) {
            TableColumn("Name", value: \.name) { p in
                HStack(spacing: 9) {
                    Image(systemName: ProcessMonitor.devRule(for: p.name) != nil ? "terminal.fill" : "cpu")
                        .foregroundStyle(ProcessMonitor.devRule(for: p.name) != nil ? Color.orange : Color.secondary)
                        .help(ProcessMonitor.devRule(for: p.name).map { "Dev process (\($0.label)) — stopped by “Stop Dev Processes”" } ?? "")
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                }
            }

            TableColumn("PID", value: \.pid) { p in
                Text("\(p.pid)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(64)

            TableColumn("CPU", value: \.cpu) { p in
                Text(String(format: "%.1f%%", p.cpu))
                    .monospacedDigit()
                    .foregroundStyle(p.cpu > 20 ? .red : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)

            TableColumn("Memory", value: \.memBytes) { p in
                Text(p.memBytes.bytesFormatted)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(100)

            TableColumn("") { p in
                HStack(spacing: 6) {
                    Button { monitor.requestKill(p) } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Terminate (SIGTERM)")
                }
            }
            .width(50)
        }
        .environment(\.defaultMinListRowHeight, 30)
        .contextMenu(forSelectionType: Int32.self) { pids in
            if let pid = pids.first, let p = monitor.entries.first(where: { $0.pid == pid }) {
                Button("Terminate") { monitor.requestKill(p) }
                Button("Force Quit", role: .destructive) { monitor.requestKill(p, force: true) }
                Divider()
                Button("Copy PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(p.pid)", forType: .string)
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.path, forType: .string)
                }
            }
        }
    }
}

// MARK: - Inspector

struct ProcInspector: View {
    @EnvironmentObject var monitor: ProcessMonitor

    private var selected: ProcessEntry? {
        monitor.entries.first { monitor.selectedPIDs.contains($0.pid) }
    }

    private var selectedCount: Int { monitor.selectedPIDs.count }

    var body: some View {
        Group {
            if let p = selected {
                HStack(spacing: 10) {
                    Image(systemName: "cpu").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("pid \(p.pid)" + (selectedCount > 1 ? " +\(selectedCount - 1) more" : ""))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(p.path)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f%%", p.cpu)).font(.callout.monospacedDigit())
                    Text(p.memBytes.bytesFormatted).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Button("Terminate") { monitor.requestKill(p) }
                        .controlSize(.small)
                    Button("Force Quit") { monitor.requestKill(p, force: true) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            } else {
                HStack {
                    Image(systemName: "cursorarrow.click").foregroundStyle(.tint)
                    Text("Select a process to inspect it or terminate it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
    }
}

// MARK: - Cleanup bar

struct ProcCleanupBar: View {
    @EnvironmentObject var monitor: ProcessMonitor

    private var selected: ProcessEntry? {
        monitor.entries.first { monitor.selectedPIDs.contains($0.pid) }
    }

    private var selectedCount: Int { monitor.selectedPIDs.count }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selected.map {
                    selectedCount > 1
                        ? "\(selectedCount) processes selected (\($0.name) +\(selectedCount - 1) more)"
                        : "Selected: \($0.name) (pid \($0.pid))"
                } ?? "Choose a process to act on")
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(monitor.statusMessage ?? "Terminate sends SIGTERM — apps can shut down gracefully. Force Quit sends SIGKILL.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(monitor.statusMessage ?? "")
            }
            Spacer(minLength: 8)
            Button { monitor.stopAllDev() } label: {
                Label("Stop Dev (\(monitor.devEntries.count))", systemImage: "stop.circle")
            }
            .controlSize(.small)
            .disabled(monitor.devEntries.isEmpty || monitor.refreshing)
            .help("SIGTERM every dev leftover: servers, watchers, build tools, local DBs")
            Button { monitor.showEndOfDay = true } label: {
                Label("End of Day…", systemImage: "moon.stars.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Stop dev processes, quit apps, and clean storage in one click")
            Button { monitor.terminateSelected() } label: {
                Label(selectedCount > 1 ? "Terminate \(selectedCount)" : "Terminate Selected", systemImage: "stop.fill")
            }
            .controlSize(.small)
            .disabled(selected == nil || monitor.refreshing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - End of day sheet

/// One-click wind-down: pick what to stop/clean, hit Run.
struct EndOfDayView: View {
    @EnvironmentObject var monitor: ProcessMonitor
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "moon.stars.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("End of day").font(.title3.weight(.bold))
                    Text("One click to wind down your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $monitor.eodStopDev) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Stop dev processes (\(monitor.devEntries.count) running)")
                            .font(.callout.weight(.medium))
                        Text("Dev servers, watchers, build tools, local DBs — SIGTERM, graceful shutdown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $monitor.eodQuitApps) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Quit other apps")
                            .font(.callout.weight(.medium))
                        Text("Non-Apple apps only; apps with unsaved work will ask to save first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $monitor.eodCleanStorage) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Clean safe storage items")
                            .font(.callout.weight(.medium))
                        Text("Selects every safe item and opens the delete review — nothing is deleted without confirming.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if monitor.devEntries.isEmpty && !monitor.eodQuitApps && !monitor.eodCleanStorage {
                Text("Nothing to do — no dev processes are running.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    if monitor.eodStopDev { _ = monitor.stopAllDev() }
                    if monitor.eodQuitApps { _ = ProcessMonitor.quitOtherApps() }
                    if monitor.eodCleanStorage { store.cleanAllSafe() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Sidebar (process mode)

struct ProcessSidebar: View {
    @EnvironmentObject var monitor: ProcessMonitor

    private var uptimeText: String {
        let secs = Int(ProcessInfo.processInfo.systemUptime)
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var topCPU: [ProcessEntry] {
        Array(monitor.entries.sorted { $0.cpu > $1.cpu }.prefix(5))
    }

    private var devLeftovers: [ProcessEntry] {
        Array(monitor.devEntries.sorted { $0.memBytes > $1.memBytes }.prefix(5))
    }

    private var thermalLabel: String {
        switch monitor.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal, .fair: return .secondary
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    var body: some View {
        List {
            Section("System") {
                statRow("CPU usage", "\(Int(monitor.totalCPU))%", icon: "cpu")
                statRow("Process memory", monitor.totalMem.bytesFormatted, icon: "memorychip")
                statRow("Processes", "\(monitor.entries.count)", icon: "square.stack.3d.up")
                statRow("Uptime", uptimeText, icon: "clock")
            }
            Section("Health") {
                statRow("Memory free", monitor.memoryFreePercent.map { "\($0)%" } ?? "—", icon: "memorychip.fill")
                statRow("Swap used", monitor.swapUsedBytes > 0 ? monitor.swapUsedBytes.bytesFormatted : "None", icon: "arrow.left.arrow.right")
                HStack(spacing: 10) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .frame(width: 27, height: 27)
                        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 7))
                    Text("Thermals").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 2)
                    Text(thermalLabel).font(.caption).monospacedDigit()
                        .foregroundStyle(thermalColor)
                }
                .padding(.vertical, 5)
                if let pct = monitor.batteryPercent {
                    statRow("Battery", "\(pct)%" + (monitor.batteryState.map { " · \($0)" } ?? ""), icon: "battery.75")
                }
            }
            if !monitor.devEntries.isEmpty {
                Section {
                    ForEach(devLeftovers) { p in
                        HStack(spacing: 8) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 2)
                            Text(String(format: "%.0f%%", p.cpu))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button { monitor.requestKill(p) } label: {
                                Image(systemName: "stop.fill")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Terminate \(p.name)")
                        }
                        .padding(.vertical, 3)
                    }
                    Button("Stop All Dev Processes") { monitor.stopAllDev() }
                        .controlSize(.small)
                } header: {
                    HStack {
                        Text("Dev leftovers")
                        Spacer()
                        Text("\(monitor.devEntries.count)")
                    }
                }
            }
            Section("Top CPU") {
                ForEach(topCPU) { p in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(p.cpu > 20 ? Color.red : Color.secondary)
                        Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(String(format: "%.0f%%", p.cpu))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func statRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 27, height: 27)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 7))
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 2)
            Text(value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}
