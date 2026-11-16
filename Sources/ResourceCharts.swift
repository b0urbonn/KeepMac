import SwiftUI
import Charts

struct ResourceSample: Identifiable {
    let date: Date
    let cpu: Double
    let memoryGB: Double
    var id: Date { date }
}

struct ResourceCharts: View {
    @EnvironmentObject var monitor: ProcessMonitor
    private var domain: ClosedRange<Date> {
        let end = monitor.history.last?.date ?? Date()
        let span = min(600, max(60, end.timeIntervalSince(monitor.history.first?.date ?? end)))
        return end.addingTimeInterval(-span)...end
    }

    var body: some View {
        HStack(spacing: 16) {
            historyCard("CPU history", unit: "% · summed across processes", color: .blue, cpu: true)
            historyCard("Resident memory", unit: "GB · process total, includes shared pages", color: .purple, cpu: false)
        }
    }

    private func historyCard(_ title: String, unit: String, color: Color, cpu: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
            Chart(monitor.history) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value(title, cpu ? sample.cpu : sample.memoryGB))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.date), y: .value(title, cpu ? sample.cpu : sample.memoryGB))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...max(cpu ? 100 : 1, monitor.history.map { cpu ? $0.cpu : $0.memoryGB }.max() ?? 0) * 1.15)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour().minute()); AxisGridLine() } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 100)
            Text(monitor.autoRefresh ? "Up to 10 minutes · live" : "Monitoring paused")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).consoleCard()
    }

    private var diskCard: some View {
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        let free = min(capacity, max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Startup disk").font(.headline)
            if capacity > 0 {
                Chart {
                    SectorMark(angle: .value("Used", capacity - free), innerRadius: .ratio(0.78), angularInset: 2)
                        .foregroundStyle(Color.mint)
                    SectorMark(angle: .value("Available", free), innerRadius: .ratio(0.78), angularInset: 2)
                        .foregroundStyle(Color.primary.opacity(0.08))
                }.frame(height: 105)
                Text("\(free.bytesFormatted) available").font(.caption.weight(.medium))
                Text("of \(capacity.bytesFormatted) · purgeable included").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Disk information unavailable").font(.caption).foregroundStyle(.secondary).frame(height: 140)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).consoleCard()
    }
}
