import Foundation
import Combine

#if canImport(FoundationModels)
import FoundationModels

@MainActor
final class Explainer: ObservableObject {
    enum State { case idle, generating, done, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var output = ""

    private var cache: [String: String] = [:]
    private var pending: Task<Void, Never>?
    private var currentID: String?

    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off. Enable it in System Settings → Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading. Try again shortly."
        case .unavailable(_):
            return "Apple Intelligence is not available right now."
        }
    }

    /// Call whenever the selected item changes — only restores a cached
    /// answer; generation happens via the explicit explain/summarize buttons.
    func select(_ item: CleanableItem?) {
        pending?.cancel()
        currentID = item?.id
        guard let item else { state = .idle; output = ""; return }
        if let cached = cache[item.id] {
            output = cached
            state = .done
            return
        }
        output = ""
        state = .idle
    }

    /// Button-triggered explanation for a single item.
    func explain(_ item: CleanableItem) {
        pending?.cancel()
        currentID = item.id
        if let cached = cache[item.id] {
            output = cached
            state = .done
            return
        }
        output = ""
        state = .generating
        pending = Task { await run(item) }
    }

    func regenerate(_ item: CleanableItem) {
        pending?.cancel()
        cache[item.id] = nil
        output = ""
        state = .generating
        pending = Task { await run(item) }
    }

    /// Summarizes a whole delete batch — used by the delete confirmation sheet.
    func summarize(_ items: [CleanableItem]) {
        pending?.cancel()
        if items.count == 1, let item = items.first {
            explain(item)
            return
        }
        let key = "batch:" + items.map(\.id).sorted().joined(separator: "|")
        currentID = key
        if let cached = cache[key] {
            output = cached
            state = .done
            return
        }
        guard Self.availabilityMessage == nil else {
            output = ""
            state = .idle
            return
        }
        output = ""
        state = .generating
        pending = Task { await runBatch(items, key: key) }
    }

    private func run(_ item: CleanableItem) async {
        let session = LanguageModelSession(instructions: """
            You are the storage assistant inside KeepMac, a macOS cleanup app. \
            Answer in at most 4 short sentences using plain language a \
            non-expert can understand. Never use markdown.
            """)
        let kind = item.isDirectory ? "folder" : "file"
        let prompt = """
            The user is about to permanently delete this \(kind) to free disk space.
            Name: \(item.name)
            Location: \(item.path.path)
            Category: \(item.category.rawValue)
            Size: \(item.size.bytesFormatted)
            App's own note: \(item.detail)

            Explain what will happen if they delete it: what it is, what (if \
            anything) stops working afterwards, what gets rebuilt or \
            re-downloaded the next time it is needed, and whether it is safe \
            to delete or what they should check first.
            """
        do {
            let response = try await session.respond(to: prompt)
            cache[item.id] = response.content
            if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
            guard currentID == item.id else { return }
            output = response.content
            state = .done
        } catch {
            guard currentID == item.id else { return }
            state = .failed
        }
    }

    private func runBatch(_ items: [CleanableItem], key: String) async {
        let session = LanguageModelSession(instructions: """
            You are the storage assistant inside KeepMac, a macOS cleanup app. \
            Answer in at most 4 short sentences using plain language a \
            non-expert can understand. Never use markdown.
            """)
        let total = items.reduce(0) { $0 + $1.size }.bytesFormatted
        let list = items.prefix(12)
            .map { "- \($0.name) (\($0.category.rawValue), \($0.size.bytesFormatted))" }
            .joined(separator: "\n")
        let prompt = """
            The user is about to permanently delete \(items.count) item(s) to \
            free \(total) of disk space. Here are the largest ones:
            \(list)

            Explain what will happen when they delete these: which ones are \
            safe because the system or tools rebuild or re-download them \
            automatically, and which ones they should double-check before \
            deleting.
            """
        do {
            let response = try await session.respond(to: prompt)
            cache[key] = response.content
            guard currentID == key else { return }
            output = response.content
            state = .done
        } catch {
            guard currentID == key else { return }
            state = .failed
        }
    }
}

#else

@MainActor
final class Explainer: ObservableObject {
    enum State { case idle, generating, done, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var output = ""
    static var availabilityMessage: String? { "This build has no Apple Intelligence support." }
    func select(_ item: CleanableItem?) { state = .idle; output = "" }
    func explain(_ item: CleanableItem) {}
    func regenerate(_ item: CleanableItem) {}
    func summarize(_ items: [CleanableItem]) {}
}
#endif
