import SwiftUI

struct ResourceOverview: View {
    @EnvironmentObject var monitor: ProcessMonitor
    @EnvironmentObject var store: Store

    private var cpu: Double? {
        monitor.lastRefresh == nil ? nil : monitor.totalCPU / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) / 100
    }

    var body: some View {
        HStack(spacing: 0) {
            gauge("COMPUTE", subtitle: "CPU capacity · estimated", value: cpu, color: .cyan, icon: "cpu", approximate: true)
            Divider().frame(height: 114)
            gauge("MEMORY", subtitle: "Available memory", value: monitor.memoryFreePercent.map { Double($0) / 100 }, color: .purple, icon: "memorychip")
            Divider().frame(height: 114)
            gauge("STORAGE", subtitle: "Startup disk used", value: DiskGaugeReading.current.usedFraction, color: .mint, icon: "internaldrive")
            Divider().frame(height: 114)
            VStack(alignment: .leading, spacing: 16) {
                smallStat("WORKLOADS", value: "\(monitor.entries.count)", note: "\(monitor.devEntries.count) developer processes", color: .orange)
                smallStat("CLEANUP CANDIDATES", value: store.items.isEmpty && store.statusText.isEmpty ? "—" : store.totalFound.bytesFormatted,
                          note: store.scanning ? "Discovering files…" : "Review before clearing", color: .mint)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24)
        }
        .padding(.vertical, 22).padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(colors: [.cyan.opacity(0.06), .clear, .purple.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        }
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.08)) }
    }

    private func gauge(_ title: String, subtitle: String, value: Double?, color: Color, icon: String, approximate: Bool = false) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(color.opacity(0.06), lineWidth: 18)
                Circle().stroke(color.opacity(0.14), lineWidth: 7)
                Circle().trim(from: 0, to: CGFloat(min(1, max(0, value ?? 0))))
                    .stroke(AngularGradient(colors: [color.opacity(0.4), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.25), radius: 6)
                VStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color)
                    Text(value.map { (approximate ? "≈" : "") + "\(Int((min(1, max(0, $0)) * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }.frame(width: 112, height: 112)
            Text(title).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(color)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func smallStat(_ label: String, value: String, note: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 4, height: 4)
                Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
