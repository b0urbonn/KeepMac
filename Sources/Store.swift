import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class Store: ObservableObject {
    @Published var items: [CleanableItem] = []
    @Published var scanning = false
    @Published var deleting = false
    @Published var statusText = ""
    @Published var selectedItemID: String?
    @Published var mode: AppMode = .storage
    @Published var categoryFilter = Set<Category>()   // empty = all categories
    @Published var kindFilter = KindFilter.all        // files / folders / all
    @Published var minSizeFilter: Int64 = 0           // bytes; 0 = any size
    @Published var reviewOnly = false                 // show only "needs review" items
    @Published var showDeleteConfirm = false
    @Published var deletionCandidates: [CleanableItem] = []
    @Published var searchText = ""
    @Published var sortOrder: [KeyPathComparator<CleanableItem>] = [KeyPathComparator(\.size, order: .reverse)]
    @Published var scanTotal = 0
    @Published var scanDone = 0
    @Published var lastResult: String?

    @AppStorage("largeFileThresholdMB") var largeFileThresholdMB = 500
    @AppStorage("scanRoots") private var scanRootsData = Data()

    private let engine = ScanEngine()
    private var scanTask: Task<Void, Never>?

    // MARK: - Roots

    var roots: [URL] {
        get {
            if let paths = try? JSONDecoder().decode([String].self, from: scanRootsData), !paths.isEmpty {
                return paths.map { URL(fileURLWithPath: $0) }
            }
            return [FileManager.default.homeDirectoryForCurrentUser]
        }
        set {
            scanRootsData = (try? JSONEncoder().encode(newValue.map(\.path))) ?? Data()
        }
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to scan for build artifacts"
        if panel.runModal() == .OK, let url = panel.url {
            var r = roots
            if !r.contains(url) { r.append(url) }
            roots = r
        }
    }

    func removeRoot(_ url: URL) { roots = roots.filter { $0 != url } }
    func resetRoots() { roots = [FileManager.default.homeDirectoryForCurrentUser] }

    // MARK: - Derived values

    /// Single-category focus used for the window title and quick-select
    /// actions; nil when zero or multiple categories are filtered.
    var selectedCategory: Category? {
        categoryFilter.count == 1 ? categoryFilter.first : nil
    }

    var viewTitle: String {
        if let c = selectedCategory { return c.rawValue }
        if categoryFilter.count > 1 { return "\(categoryFilter.count) categories" }
        return "Storage Overview"
    }

    var hasActiveFilters: Bool {
        !categoryFilter.isEmpty || kindFilter != .all || minSizeFilter > 0
            || reviewOnly || !searchText.isEmpty
    }

    /// Binding that lets the sidebar's single-selection List drive the
    /// multi-select category filter: one category → that set, "All Items" → empty.
    var categorySelection: Binding<Category?> {
        Binding(
            get: { self.categoryFilter.count == 1 ? self.categoryFilter.first : nil },
            set: { self.categoryFilter = $0.map { Set([$0]) } ?? [] }
        )
    }

    func selectCategory(_ cat: Category) { categoryFilter = [cat] }

    func toggleCategory(_ cat: Category) {
        if categoryFilter.contains(cat) { categoryFilter.remove(cat) }
        else { categoryFilter.insert(cat) }
    }

    func clearFilters() {
        categoryFilter = []
        kindFilter = .all
        minSizeFilter = 0
        reviewOnly = false
        searchText = ""
    }

    /// Items after every active filter: category, kind, minimum size,
    /// needs-review, and the name/path search text.
    var visibleItems: [CleanableItem] {
        var list = items
        if !categoryFilter.isEmpty {
            list = list.filter { categoryFilter.contains($0.category) }
        }
        switch kindFilter {
        case .files: list = list.filter { !$0.isDirectory }
        case .folders: list = list.filter { $0.isDirectory }
        case .all: break
        }
        if minSizeFilter > 0 { list = list.filter { $0.size >= minSizeFilter } }
        if reviewOnly { list = list.filter(\.caution) }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.path.path.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    func items(for category: Category?) -> [CleanableItem] {
        items
            .filter { category == nil || $0.category == category }
            .sorted { $0.size > $1.size }
    }

    var selectedItems: [CleanableItem] { items.filter(\.isSelected) }
    var totalFound: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalSelected: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var deletionTotal: Int64 { deletionCandidates.reduce(0) { $0 + $1.size } }

    func setSelection(_ value: Bool, for category: Category?) {
        // nil means "the current view": the filtered categories, or everything.
        let cats = category.map { Set([$0]) } ?? (categoryFilter.isEmpty ? nil : categoryFilter)
        for i in items.indices where (cats?.contains(items[i].category) ?? true) {
            if items[i].caution && value { continue }   // never mass-select caution items
            items[i].isSelected = value
        }
    }

    // MARK: - Scanning

    func rescan() {
        scanTask?.cancel()
        let roots = self.roots
        let threshold = Int64(largeFileThresholdMB) * 1024 * 1024
        scanning = true
        statusText = "Searching for cleanable items…"
        items = []
        selectedItemID = nil
        scanTotal = 0
        scanDone = 0
        scanTask = Task { [engine] in
            let found = await engine.collect(roots: roots, largeFileThreshold: threshold) { path in
                Task { @MainActor in self.statusText = "Scanning \(path)…" }
            }
            guard !Task.isCancelled else { return }
            statusText = "Measuring \(found.count) items…"
            scanTotal = found.count

            var measured = 0
            var batch: [CleanableItem] = []
            await withTaskGroup(of: CleanableItem.self) { group in
                var pending = found.makeIterator()
                var inFlight = 0
                func enqueue() -> Bool {
                    guard let f = pending.next() else { return false }
                    group.addTask {
                        let size = f.isDirectory ? SizeMeasurer.measure(f.path, isDirectory: true)
                                                 : f.enumeratorSize
                        return CleanableItem(path: f.path, name: f.name, category: f.category,
                                             isDirectory: f.isDirectory, detail: f.detail,
                                             caution: f.caution, size: size,
                                             isSelected: !f.caution)
                    }
                    return true
                }
                while inFlight < 8 && enqueue() { inFlight += 1 }
                for await item in group {
                    batch.append(item)
                    inFlight -= 1
                    measured += 1
                    scanDone = measured
                    if batch.count >= 16 {
                        let chunk = batch
                        batch.removeAll()
                        await MainActor.run { self.items.append(contentsOf: chunk) }
                    }
                    if measured % 25 == 0 {
                        statusText = "Measuring \(found.count) items… \(measured)/\(found.count)"
                    }
                    if enqueue() { inFlight += 1 }
                }
            }
            if !batch.isEmpty { items.append(contentsOf: batch) }
            scanning = false
            if selectedItemID == nil { selectedItemID = items.first?.id }
            statusText = items.isEmpty ? "Nothing found — your disk is tidy."
                                       : "Found \(items.count) items"
        }
    }

    // MARK: - Deleting

    nonisolated private static func performDelete(_ items: [CleanableItem]) -> (removed: Set<String>, freed: Int64, failed: [String]) {
        var freed: Int64 = 0
        var failed: [String] = []
        var removed = Set<String>()
        let fm = FileManager.default
        for item in items {
            // Safety: never allow deleting a path shallower than /Users/x/y
            guard item.path.pathComponents.count > 3 else { failed.append(item.name); continue }
            do {
                try fm.removeItem(at: item.path)
                freed += item.size
                removed.insert(item.id)
            } catch {
                failed.append("\(item.name): \(error.localizedDescription)")
            }
        }
        return (removed, freed, failed)
    }

    func requestDelete(_ candidates: [CleanableItem]) {
        guard !candidates.isEmpty else { return }
        deletionCandidates = candidates
        showDeleteConfirm = true
    }

    func deleteSelected() {
        requestDelete(selectedItems)
    }

    func confirmDeletion() {
        let sel = deletionCandidates
        deletionCandidates = []
        guard !sel.isEmpty else { return }
        deleting = true
        statusText = "Deleting \(sel.count) items…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.performDelete(sel)
            }.value
            items.removeAll { result.removed.contains($0.id) }
            deleting = false
            var msg = "Freed \(result.freed.bytesFormatted)"
            if !result.failed.isEmpty {
                msg += " — \(result.failed.count) item(s) could not be deleted"
                if let first = result.failed.first { msg += " (\(first))" }
            }
            statusText = msg
            lastResult = msg
        }
    }

    func reveal(_ item: CleanableItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.path])
    }

    func copyPath(_ item: CleanableItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path.path, forType: .string)
    }
}
