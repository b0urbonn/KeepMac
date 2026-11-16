import SwiftUI
import Charts

struct DashboardView: View {
    var scrolls = true
    @EnvironmentObject var store: Store
    @EnvironmentObject var monitor: ProcessMonitor
    @Environment(\.openSettings) private var openSettings

    private var awaitingScan: Bool { store.items.isEmpty && store.statusText.isEmpty }
    private var safeBytes: Int64 { store.items.filter { !$0.caution }.reduce(0) { $0 + $1.size } }
    private var thermal: String {
        switch monitor.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { dashboardContent }
            } else {
                dashboardContent
            }
        }
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(alignment: .topLeading) {
                    RadialGradient(colors: [.cyan.opacity(0.055), .clear], center: .topLeading, startRadius: 0, endRadius: 650)
                }
        }
    }

    var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("KEEPMAC  /  RESOURCE MONITOR")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.6).foregroundStyle(.secondary)
                        Text("Mission control.")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Your Mac. Every resource in view.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(monitor.lastRefresh == nil ? "Connecting" : monitor.autoRefresh ? "Live monitoring" : "Monitoring paused", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.mint)
                        .padding(10).background(.mint.opacity(0.08), in: .capsule)
                }
                ResourceOverview()
                ResourceCharts()
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("Storage management", subtitle: "Generated files and development data")
                        if store.items.isEmpty {
                            Text(store.scanning ? "Measuring cleanup candidates…" : "Scan storage to see category sizes.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        } else {
                        Chart(Category.allCases) { category in
                            let bytes = store.items(for: category).reduce(Int64(0)) { $0 + $1.size }
                            BarMark(x: .value("GB", Double(bytes) / 1_000_000_000), y: .value("Category", category.rawValue))
                                .foregroundStyle(category.color)
                        }
                        .chartXAxisLabel("GB · cleanup candidates")
                        .frame(height: 110)
                        }
                        ForEach(Category.allCases) { category in
                            Button {
                                store.categoryFilter = [category]
                                store.mode = .storage
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: category.icon).foregroundStyle(category.color)
                                        .frame(width: 34, height: 34)
                                        .background(category.color.opacity(0.1), in: .rect(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(category.rawValue).font(.system(size: 13, weight: .semibold))
                                        Text("\(store.items(for: category).count) items").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(store.items(for: category).reduce(Int64(0)) { $0 + $1.size }.bytesFormatted)
                                        .monospacedDigit().font(.callout.weight(.medium))
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if category != Category.allCases.last { Divider() }
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(safeBytes.bytesFormatted) in safe candidates").font(.callout.weight(.semibold))
                                Text("Review the deletion list before clearing.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review cleanup…") { store.cleanAllSafe() }
                                .disabled(store.scanning || store.deleting || safeBytes == 0)
                        }
                    }
                    .consoleCard()
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            sectionTitle("Active workloads", subtitle: "Highest CPU usage")
                            Spacer()
                            Button("View all") { store.mode = .processes }.buttonStyle(.link)
                        }
                        if monitor.entries.isEmpty {
                            Text("Waiting for process samples…").foregroundStyle(.secondary).padding(.vertical, 30)
                        }
                        ForEach(monitor.entries.sorted { $0.cpu > $1.cpu }.prefix(5)) { process in
                            HStack(spacing: 10) {
                                Image(systemName: "terminal").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("PID \(process.pid) · \(process.memBytes.bytesFormatted)")
                                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f%%", process.cpu)).monospacedDigit().font(.callout)
                            }.padding(.vertical, 4)
                            GeometryReader { geometry in
                                Capsule().fill(Color.cyan.opacity(0.1))
                                Capsule().fill(Color.cyan.opacity(0.6))
                                    .frame(width: geometry.size.width * min(1, process.cpu / max(100, monitor.entries.map(\.cpu).max() ?? 100)))
                            }.frame(height: 3)
                        }
                        Divider()
                        HStack {
                            Label("Thermals: \(thermal)", systemImage: "thermometer.medium")
                            Spacer()
                            Text("Swap: \(monitor.swapUsedBytes.bytesFormatted)")
                        }.font(.caption).foregroundStyle(.secondary)
                        Text("Memory free: \(monitor.memoryFreePercent.map { "\($0)%" } ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .consoleCard()
                }
                HStack(spacing: 16) {
                    tool("End-of-day maintenance", detail: "Review developer processes and cleanup tasks.", icon: "moon.stars") {
                        monitor.showEndOfDay = true
                    }
                    tool("Activity Monitor", detail: "Open macOS system diagnostics and resource details.", icon: "waveform.path.ecg") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                    tool("Scan configuration", detail: "Manage project roots and large-file thresholds.", icon: "slider.horizontal.3") {
                        openSettings()
                    }
                }
                HStack {
                    Image(systemName: store.scanning ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    Text(store.scanning || store.deleting ? store.statusText : (store.lastResult ?? (awaitingScan ? "Ready to scan. No storage scan has run this session." : "Storage candidates require review. No automatic deletion.")))
                    Spacer()
                    if let date = monitor.lastRefresh {
                        Text("Processes updated \(date, style: .relative) ago")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if store.scanning && store.scanTotal > 0 {
                    ProgressView(value: Double(store.scanDone), total: Double(store.scanTotal))
                }
            }.padding(28)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, value: String, note: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).foregroundStyle(color)
            }
            Text(value).font(.system(size: 27, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).consoleCard()
    }

    private func tool(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).foregroundStyle(.tint).font(.title3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).consoleCard()
        }.buttonStyle(.plain)
    }
}

extension View {
    func consoleCard() -> some View {
        self.padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(LinearGradient(colors: [.primary.opacity(0.12), .primary.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)) }
            .shadow(color: .black.opacity(0.025), radius: 10, y: 4)
    }
}
