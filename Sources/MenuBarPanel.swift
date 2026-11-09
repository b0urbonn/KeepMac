import SwiftUI

/// Compact panel shown from the menu-bar extra: scan status, reclaimable
/// total, the biggest items found, and quick actions — so cleanup is one
/// click away without opening the full window.
struct MenuBarPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    private var topItems: [CleanableItem] {
        Array(store.items.sorted { $0.size > $1.size }.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.tint)
                Text("KeepMac").font(.headline)
                Spacer()
                if store.scanning || store.deleting {
                    ProgressView().controlSize(.small)
                }
            }

            if store.scanning {
                if store.scanTotal > 0 {
                    ProgressView(value: Double(store.scanDone), total: Double(store.scanTotal))
                        .controlSize(.small)
                }
                Text(store.statusText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(store.totalFound.bytesFormatted)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(store.items.count) items found · \(store.selectedItems.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                if let result = store.lastResult {
                    Text(result)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if !topItems.isEmpty {
                Divider()
                ForEach(topItems) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(item.size.bytesFormatted)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if store.items.count > topItems.count {
                    Text("…and \(store.items.count - topItems.count) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button("Rescan") { store.rescan() }
                    .disabled(store.scanning || store.deleting)
                Button("Clean All Safe…") {
                    openWindow(id: "main")
                    store.cleanAllSafe()
                }
                .disabled(!store.items.contains { !$0.caution } || store.scanning || store.deleting)
                .help("Select every safe item and review them for deletion")
                Spacer()
                Button("Open") { openWindow(id: "main") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }
}
