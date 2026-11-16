import SwiftUI
import Charts

/// Glanceable menu-bar readout backed by the same monitor as the dashboard.
struct MenuBarStatusLabel: View {
    @ObservedObject var store: Store
    @ObservedObject var monitor: ProcessMonitor

    private var cpuFraction: Double {
        monitor.totalCPU / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) / 100
    }

    var body: some View {
        Image(nsImage: statusRings)
            .accessibilityLabel("KeepMac: CPU, free memory, disk usage")
            .help("KeepMac · CPU capacity ≈\(Int(cpuFraction * 100))% · Memory \(monitor.memoryFreePercent.map { "\($0)% free" } ?? "unavailable") · Disk \(DiskGaugeReading.current.usedPercentText) used · Click for charts")
    }

    // A template image stays legible in both light and dark macOS menu bars.
    private var statusRings: NSImage {
        let disk = DiskGaugeReading.current
        let fractions: [Double?] = [monitor.lastRefresh == nil ? nil : cpuFraction,
                                   monitor.memoryFreePercent.map { Double($0) / 100 }, disk.usedFraction]
        let image = NSImage(size: NSSize(width: 62, height: 20), flipped: false) { bounds in
            for (index, fraction) in fractions.enumerated() {
                let center = NSPoint(x: 10 + index * 21, y: 10)
                let track = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: 3, width: 14, height: 14))
                track.lineWidth = 2.5
                NSColor.labelColor.withAlphaComponent(0.22).setStroke()
                track.stroke()
                if let fraction {
                    let arc = NSBezierPath()
                    arc.lineWidth = 2.5
                    arc.lineCapStyle = .round
                    arc.appendArc(withCenter: center, radius: 7, startAngle: 90,
                                  endAngle: 90 - CGFloat(min(1, max(0, fraction))) * 360, clockwise: true)
                    NSColor.labelColor.setStroke()
                    arc.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

}

struct MenuBarPanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var monitor: ProcessMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var thermal: String {
        switch monitor.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func open(_ mode: AppMode) {
        store.mode = mode
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("KeepMac", systemImage: "terminal.fill").font(.headline)
                Spacer()
                Label(monitor.autoRefresh ? "Live" : "Paused", systemImage: monitor.autoRefresh ? "circle.fill" : "pause.circle")
                    .font(.caption2).foregroundStyle(monitor.autoRefresh ? Color.green : .secondary)
            }
            HStack(spacing: 12) {
                ResourceDonut(title: "CPU capacity", value: monitor.lastRefresh == nil ? nil : monitor.totalCPU / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) / 100,
                              color: .blue, approximate: true)
                ResourceDonut(title: "Memory free", value: monitor.memoryFreePercent.map { Double($0) / 100 }, color: .purple)
                ResourceDonut(title: "Disk used", value: DiskGaugeReading.current.usedFraction, color: .mint)
            }
            HStack(spacing: 12) {
                metric("CPU · all processes", value: monitor.lastRefresh == nil ? "—" : "\(Int(monitor.totalCPU))%", color: .blue, cpu: true)
                metric("Process memory", value: monitor.lastRefresh == nil ? "—" : monitor.totalMem.bytesFormatted, color: .purple, cpu: false)
            }
            HStack {
                Text("Thermals: \(thermal)")
                Spacer()
                Text("Swap: \(monitor.swapUsedBytes.bytesFormatted)")
            }.font(.caption).foregroundStyle(.secondary)
            Text("CPU ring ≈ process CPU ÷ cores. Memory ring shows free memory.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Text("Disk: \(DiskGaugeReading.current.freeText) available · process memory includes shared pages")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Storage cleanup", systemImage: "internaldrive").font(.callout.weight(.semibold))
                    Text(store.scanning ? "Scanning…" : store.statusText.isEmpty && store.items.isEmpty ? "Ready to scan" : "\(store.totalFound.bytesFormatted) in candidates")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.scanning { ProgressView().controlSize(.small) }
            }
            if store.scanning {
                Text(store.statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if store.scanTotal > 0 {
                    ProgressView(value: Double(store.scanDone), total: Double(store.scanTotal))
                }
            }
            HStack {
                Button("Scan storage") { store.rescan() }
                    .disabled(store.scanning || store.deleting)
                Spacer()
                Button("Clean All Safe…") {
                    open(.storage)
                    store.cleanAllSafe()
                }
                .disabled(!store.items.contains { !$0.caution } || store.scanning || store.deleting)
                .help("Review safe candidates before permanent deletion")
            }.controlSize(.small)
            Divider()
            HStack(spacing: 8) {
                Button { open(.overview) } label: {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }.buttonStyle(.borderedProminent)
                Button { open(.processes) } label: {
                    Label("Processes", systemImage: "waveform.path.ecg")
                }
                Spacer(minLength: 0)
                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Image(systemName: "gearshape") }.help("Settings")
            }.controlSize(.small)
            HStack {
                if let date = monitor.lastRefresh {
                    Text("Updated \(date, style: .relative) ago")
                } else {
                    Text("Waiting for first sample")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 370)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(LinearGradient(colors: [.cyan.opacity(0.07), .clear, .purple.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func metric(_ title: String, value: String, color: Color, cpu: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
            Chart(monitor.history) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value(title, cpu ? sample.cpu : sample.memoryGB))
                    .foregroundStyle(color.opacity(0.12))
                LineMark(x: .value("Time", sample.date), y: .value(title, cpu ? sample.cpu : sample.memoryGB))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: 0...max(cpu ? 100 : 1, monitor.history.map { cpu ? $0.cpu : $0.memoryGB }.max() ?? 0) * 1.1)
            .frame(height: 42)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.05), in: .rect(cornerRadius: 10))
    }
}

/// Available capacity includes space macOS can purge; unavailable reads stay empty.
struct DiskGaugeReading {
    let capacity: Int64
    let free: Int64
    var usedFraction: Double? { capacity > 0 ? Double(capacity - free) / Double(capacity) : nil }
    var usedPercentText: String { usedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    var freeText: String { capacity > 0 ? free.bytesFormatted : "—" }
    static var current: DiskGaugeReading {
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        return DiskGaugeReading(capacity: total, free: min(total, max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0)))
    }
}

struct ResourceDonut: View {
    let title: String
    let value: Double?
    let color: Color
    var approximate = false

    private var fraction: Double { min(1, max(0, value ?? 0)) }
    private var valueText: String {
        guard value != nil else { return "—" }
        return (approximate ? "≈" : "") + "\(Int((fraction * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(color.opacity(0.06), lineWidth: 14)
                Circle().stroke(color.opacity(0.14), lineWidth: 6)
                Circle().trim(from: 0, to: fraction)
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.25), radius: 4)
                Text(valueText).font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6).padding(9)
            }.frame(width: 78, height: 78)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(valueText)")
    }
}
