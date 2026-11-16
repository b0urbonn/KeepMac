import SwiftUI
import AppKit

/// Reaches the backing NSWindow once attached and applies AppKit tweaks
/// SwiftUI can't express — here: no window tab bar (removes the stray
/// gray bar with the "+" new-tab button).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        func apply() {
            guard let window = view.window else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { apply() }
                return
            }
            window.tabbingMode = .disallowed
        }
        DispatchQueue.main.async { apply() }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.tabbingMode = .disallowed
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var monitor: ProcessMonitor
    @EnvironmentObject var preferences: AppPreferences

    private var shownItems: [CleanableItem] {
        store.visibleItems.sorted(using: store.sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            consoleHeader
            Divider()
            Group {
                switch store.mode {
                case .overview: DashboardView()
                case .processes: ProcessDetailView()
                case .storage: storageWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowConfigurator())
        .navigationTitle("KeepMac")
        .sheet(isPresented: $store.showDeleteConfirm) {
            DeleteConfirmView().environmentObject(store)
        }
        .sheet(isPresented: $monitor.showEndOfDay) { EndOfDayView() }
        .sheet(isPresented: $preferences.showSetup) { SetupView() }
    }

    private var consoleHeader: some View {
        HStack(spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.title3).foregroundStyle(.mint)
                    .frame(width: 36, height: 36)
                    .background(.mint.opacity(0.12), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("KeepMac").font(.system(size: 15, weight: .bold))
                    Text("DEVELOPER CONSOLE")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(1.2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                ForEach(AppMode.allCases) { mode in
                    Button { store.mode = mode } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13).padding(.vertical, 10)
                            .foregroundStyle(store.mode == mode ? Color.primary : Color.secondary)
                            .background(store.mode == mode ? Color.accentColor.opacity(0.13) : .clear,
                                        in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.mode == mode ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12))
            Spacer(minLength: 0)
            Button { store.rescan() } label: {
                Label(store.scanning ? "Scanning…" : "Scan storage", systemImage: "arrow.clockwise")
            }
            .disabled(store.scanning || store.deleting)
            .help("Scan storage again (⌘R)")
            SettingsLink { Label("Settings", systemImage: "slider.horizontal.3") }
                .help("Settings")
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var storageWorkspace: some View {
        VStack(spacing: 0) {
            HeaderView().padding(.top, 10)
            HStack(spacing: 8) {
                categoryButton(nil)
                ForEach(Category.allCases) { category in categoryButton(category) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            VStack(spacing: 0) {
                BrowserHeader(count: shownItems.count).padding(.vertical, 10)
                FilterBar().padding(.bottom, 8)
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.selectedItemID != nil {
                    Divider()
                    DetailPanel(compact: false)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)) }
            .padding(.horizontal, 24).padding(.bottom, 12)
            CleanupBar()
        }
    }

    private func categoryButton(_ category: Category?) -> some View {
        let active = category == nil ? store.categoryFilter.isEmpty : store.categoryFilter == Set([category!])
        return Button {
            store.categoryFilter = category.map { Set([$0]) } ?? []
        } label: {
            Label(category?.rawValue ?? "All storage", systemImage: category?.icon ?? "internaldrive")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                            in: .rect(cornerRadius: 7))
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if store.scanning && store.items.isEmpty {
            Spacer()
            ProgressView { Text(store.statusText) }
            Spacer()
        } else if shownItems.isEmpty {
            Spacer()
            emptyState
            Spacer()
        } else {
            ItemTable(items: shownItems)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if store.scanning {
            ContentUnavailableView(
                "Scanning…",
                systemImage: "magnifyingglass",
                description: Text(store.statusText)
            )
        } else if !store.searchText.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing matches “\(store.searchText)” in this category.")
            } actions: {
                Button("Clear Filter") { store.searchText = "" }
            }
        } else if store.hasActiveFilters {
            ContentUnavailableView {
                Label("No matches", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No items match the current filters.")
            } actions: {
                Button("Reset Filters") { store.clearFilters() }
            }
        } else {
            ContentUnavailableView {
                Label("Nothing here", systemImage: "checkmark.seal")
            } description: {
                Text("No items in this category. Run a scan or pick another category.")
            } actions: {
                Button("Rescan") { store.rescan() }
            }
        }
    }
}

// MARK: - Navigation

struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive.fill")
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("KeepMac").font(.headline)
                Text("Room for your next idea.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SidebarRow: View {
    let label: String
    let icon: String
    let count: Int
    let size: Int64
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 27, height: 27)
                .background(color.opacity(0.12), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text((count == 1 ? "1 item" : "\(count) items") + (count > 0 ? " · \(size.bytesFormatted)" : ""))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 2)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Made for developer space", systemImage: "terminal")
                .font(.caption.weight(.medium))
            Text("Build output, tool caches, and models. Review what you need, clear what you don’t.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink {
                Label("Scan settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.link).font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        .padding(14)
    }
}

// MARK: - Overview

struct HeaderView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.selectedCategory?.rawValue ?? "Storage workspace")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(store.selectedCategory?.subtitle ?? "Inspect generated files, tool caches, and local model data.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(store.selectedCategory?.subtitle ?? "Inspect generated files, tool caches, and local model data.")
                }
                Spacer(minLength: 0)
                if store.scanning || store.deleting {
                    ProgressView().controlSize(.small)
                        .padding(.top, 7)
                        .accessibilityLabel(store.scanning ? "Scanning storage" : "Deleting items")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 8)
            if store.scanning && store.scanTotal > 0 {
                ProgressView(value: Double(store.scanDone), total: Double(store.scanTotal))
                    .controlSize(.small)
                    .frame(height: 2)
                    .padding(.horizontal, 24)
                    .accessibilityLabel("Items measured")
        }
        }
    }
}

struct StorageBar: View {
    @EnvironmentObject var store: Store
    var compact = false

    private struct Segment: Identifiable {
        let cat: Category
        let size: Int64
        var id: String { cat.id }
    }

    private var segments: [Segment] {
        Category.allCases
            .map { cat in Segment(cat: cat, size: store.items(for: cat).reduce(0) { $0 + $1.size }) }
            .filter { $0.size > 0 }
    }
    private var total: Int64 { store.totalFound }
    private var diskText: String {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage,
              let capacity = v.volumeTotalCapacity else { return "This Mac" }
        return "\(free.bytesFormatted) available of \(Int64(capacity).bytesFormatted)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.scanning ? "DISCOVERED SO FAR" : "POTENTIAL SPACE TO RECLAIM")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(total.bytesFormatted)
                        .font(.system(size: compact ? 26 : 38, weight: .semibold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Label("This Mac", systemImage: "internaldrive")
                        .font(.callout.weight(.medium))
                    Text(diskText).font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(segments) { seg in
                        Button { store.selectCategory(seg.cat) } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(seg.cat.color.gradient)
                                .frame(width: max(0, geo.size.width - CGFloat(max(segments.count - 1, 0)) * 3) * CGFloat(seg.size) / CGFloat(max(total, 1)))
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(seg.cat.rawValue): \(seg.size.bytesFormatted)")
                        .accessibilityLabel("\(seg.cat.rawValue), \(seg.size.bytesFormatted)")
                    }
                }
            }
            .frame(height: compact ? 10 : 14)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { legend }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) { legend }
            }
        }
        .padding(compact ? 10 : 20)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .windowBackgroundColor).gradient)
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.accentColor.opacity(0.045))
                }
        }
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.07)) }
        .padding(.horizontal, 24)
        .padding(.bottom, compact ? 8 : 20)
        .help("Potential space includes items that need your review before deletion.")
    }

    @ViewBuilder private var legend: some View {
        ForEach(segments) { seg in
            Button { store.selectCategory(seg.cat) } label: {
                HStack(spacing: 5) {
                    Circle().fill(seg.cat.color).frame(width: 7, height: 7)
                    Text(seg.cat.rawValue)
                    Text(seg.size.bytesFormatted).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 11))
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Show \(seg.cat.rawValue)")
        }
    }
}

// MARK: - Browser controls

struct BrowserHeader: View {
    @EnvironmentObject var store: Store
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(.headline).monospacedDigit()
            Menu {
                Button("Select All Items") { store.setSelection(true, for: store.selectedCategory, includeCaution: true) }
                Button("Select Safe Items") { store.setSelection(true, for: store.selectedCategory) }
                Divider()
                Button("Deselect All") { store.setSelection(false, for: store.selectedCategory) }
            } label: {
                Label("Select", systemImage: "checklist")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.scanning || store.deleting || count == 0)
            .help("Applies to this category, including filtered-out items. \"Select All\" includes needs-review items; \"Select Safe Items\" skips them.")
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter name or path", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter items by name or path")
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear filter")
                    .accessibilityLabel("Clear filter")
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

// MARK: - Filter bar

struct FilterBar: View {
    @EnvironmentObject var store: Store

    private static let sizePresets: [(label: String, bytes: Int64)] = [
        ("Any size", 0),
        ("≥ 50 MB", 50 * 1024 * 1024),
        ("≥ 100 MB", 100 * 1024 * 1024),
        ("≥ 500 MB", 500 * 1024 * 1024),
        ("≥ 1 GB", 1024 * 1024 * 1024),
        ("≥ 5 GB", 5 * 1024 * 1024 * 1024),
    ]

    private var categoryLabel: String {
        if store.categoryFilter.isEmpty { return "All categories" }
        if store.categoryFilter.count == 1, let c = store.categoryFilter.first { return c.rawValue }
        return "\(store.categoryFilter.count) categories"
    }

    private var sizeLabel: String {
        guard store.minSizeFilter > 0 else { return "Any size" }
        return "≥ \(store.minSizeFilter.bytesFormatted)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Category.allCases) { cat in
                    Button { store.toggleCategory(cat) } label: {
                        if store.categoryFilter.contains(cat) {
                            Label(cat.rawValue, systemImage: "checkmark")
                        } else {
                            Text(cat.rawValue)
                        }
                    }
                }
                if !store.categoryFilter.isEmpty {
                    Divider()
                    Button("All categories") { store.categoryFilter = [] }
                }
            } label: {
                Label(categoryLabel, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter by category — select several to combine them")

            Menu {
                ForEach(KindFilter.allCases) { kind in
                    Button { store.kindFilter = kind } label: {
                        if store.kindFilter == kind {
                            Label(kind.rawValue, systemImage: "checkmark")
                        } else {
                            Text(kind.rawValue)
                        }
                    }
                }
            } label: {
                Label("Kind: \(store.kindFilter.rawValue)", systemImage: "square.stack")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show only files or only folders")

            Menu {
                ForEach(Self.sizePresets, id: \.bytes) { preset in
                    Button { store.minSizeFilter = preset.bytes } label: {
                        if store.minSizeFilter == preset.bytes {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } label: {
                Label("Size: \(sizeLabel)", systemImage: "scalemass")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Only show items at least this large")

            Toggle("Needs review", isOn: $store.reviewOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show only items flagged as needing review before deletion")

            Spacer(minLength: 8)

            if store.hasActiveFilters {
                Button("Reset") { store.clearFilters() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }
}

struct CleanupBar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.selectedItems.isEmpty ? "Choose what to clear" : "\(store.selectedItems.count) items selected · \(store.totalSelected.bytesFormatted)")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                Text(store.scanning || store.deleting ? store.statusText : (store.lastResult ?? "Deletion is permanent. You’ll review a confirmation first."))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(store.statusText)
            }
            Spacer(minLength: 8)
            Button { store.cleanAllSafe() } label: {
                Label("Clean All Safe", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!store.items.contains { !$0.caution } || store.deleting || store.scanning)
            .help("Select every safe item and review them for deletion — needs-review items are skipped")
            Button { store.deleteSelected() } label: {
                Label("Delete Selected…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(store.selectedItems.isEmpty || store.deleting || store.scanning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Item table

struct ItemTable: View {
    @EnvironmentObject var store: Store
    let items: [CleanableItem]

    var body: some View {
        Table(items, selection: $store.selectedItemID, sortOrder: $store.sortOrder) {
            TableColumn("") { item in
                Toggle("Select \(item.name)", isOn: selectionBinding(for: item))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(store.scanning || store.deleting)
            }
            .width(26)

            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 9) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.caution {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Review before deleting — see the note below.")
                    }
                }
            }

            TableColumn("Category", value: \.category.rawValue) { item in
                Label(item.category.rawValue, systemImage: item.category.icon)
                    .font(.caption)
                    .foregroundStyle(item.category.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 80, ideal: 130, max: 180)

            TableColumn("Location", value: \.path.path) { item in
                Text((item.path.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TableColumn("Size", value: \.size) { item in
                Text(item.size.bytesFormatted)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

            TableColumn("") { item in
                HStack(spacing: 6) {
                    Button { store.reveal(item) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    Button(role: .destructive) { store.requestDelete([item]) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete permanently…")
                    .disabled(store.scanning || store.deleting)
                }
            }
            .width(60)
        }
        .environment(\.defaultMinListRowHeight, 38)
        .contextMenu(forSelectionType: CleanableItem.ID.self) { ids in
            if let id = ids.first, let item = store.items.first(where: { $0.id == id }) {
                Button("Reveal in Finder") { store.reveal(item) }
                Button("Copy Path") { store.copyPath(item) }
                Divider()
                Button("Delete…", role: .destructive) { store.requestDelete([item]) }
            }
        }
    }

    private func selectionBinding(for item: CleanableItem) -> Binding<Bool> {
        Binding(
            get: { store.items.first { $0.id == item.id }?.isSelected ?? item.isSelected },
            set: { v in if let i = store.items.firstIndex(where: { $0.id == item.id }) { store.items[i].isSelected = v } }
        )
    }
}

// MARK: - Delete confirmation sheet

struct DeleteConfirmView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    private var items: [CleanableItem] { store.deletionCandidates }
    private var total: Int64 { items.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 40, height: 40)
                    .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Permanently delete?").font(.headline)
                    Text("\(items.count) \(items.count == 1 ? "item" : "items") · frees \(total.bytesFormatted) · cannot be undone")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items.prefix(8)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            if item.caution {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(item.size.bytesFormatted)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.vertical, 5)
                        if item.id != items.prefix(8).last?.id { Divider() }
                    }
                    if items.count > 8 {
                        Divider()
                        Text("…and \(items.count - 8) more")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: 190)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))


            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete \(items.count) \(items.count == 1 ? "item" : "items") (\(total.bytesFormatted))", role: .destructive) {
                    store.confirmDeletion()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)

    }

}

// MARK: - Detail / explanation panel

struct DetailPanel: View {
    @EnvironmentObject var store: Store
    var compact = false

    private var item: CleanableItem? {
        store.items.first { $0.id == store.selectedItemID }
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                            Text(item.name).font(.headline).lineLimit(1)
                            Text("·").foregroundStyle(.secondary)
                            Text(item.size.bytesFormatted).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                            if item.caution {
                                Label("Review first", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button { store.copyPath(item) } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy path")
                            Button { store.reveal(item) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                        Text(item.path.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: compact ? 124 : 178)
            } else {
                HStack {
                    Image(systemName: "cursorarrow.click").foregroundStyle(.tint)
                    Text("Select an item to see what it is and whether it's safe to delete.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
    }
}
