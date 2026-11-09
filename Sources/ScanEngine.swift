import Foundation

actor ScanEngine {
    struct Found {
        let path: URL
        let name: String
        let category: Category
        let isDirectory: Bool
        let detail: String
        let caution: Bool
        let enumeratorSize: Int64  // only used for large files; dirs measured with du later
    }

    // Names that always mean "generated dependency/build output".
    private let specificNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "__pycache__", ".venv", "venv",
        ".tox", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".turbo", ".next",
        ".nuxt", ".parcel-cache", ".nyc_output", "coverage", ".dart_tool",
        "bower_components", "Pods", ".gradle",
    ]

    // Generic output names — only collected when a project manifest sits next to them.
    private let genericNames: Set<String> = ["build", "dist", "out", "target", "bin", "obj"]

    private let manifestNames: Set<String> = [
        "package.json", "Cargo.toml", "pyproject.toml", "setup.py", "go.mod",
        "pom.xml", "build.gradle", "build.gradle.kts", "Package.swift",
        "composer.json", "Gemfile", "requirements.txt", "CMakeLists.txt",
        "Makefile", "pubspec.yaml", "Podfile",
    ]

    // Directories never descended into during the project walk.
    private let pruneNames: Set<String> = [".git", ".svn", ".hg", ".Trash", "Photos Library.photoslibrary"]

    private let maxDepth = 8
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Tool-internal dirs the walk must not treat as project space —
    /// bundled runtimes/plugins inside them aren't user dependencies, so
    /// node_modules/.build matches there would be false positives. Their
    /// real cleanables are claimed by the fixed collectors regardless.
    private lazy var walkPrunePrefixes: [String] = [
        ".claude", ".codex", ".gemini", ".copilot", ".continue", ".aider",
        ".codeium", ".tabnine", ".cursor", ".windsurf", ".config",
        ".local/share/devin", ".local/share/claude",
        ".vscode-shared", ".vscode-react-native",
    ].map { "\(home.path)/\($0)" }

    /// Collect every candidate path. Directory sizes are measured afterwards.
    /// `progress` is invoked periodically with the path currently being walked.
    func collect(roots: [URL], largeFileThreshold: Int64,
                 progress: (@Sendable (String) -> Void)? = nil) -> [Found] {
        var found: [Found] = []
        var seenPaths = Set<String>()

        func add(_ url: URL, _ name: String, _ cat: Category, _ isDir: Bool, _ detail: String, _ caution: Bool, _ size: Int64 = 0) {
            let key = url.path
            guard !seenPaths.contains(key) else { return }
            seenPaths.insert(key)
            found.append(Found(path: url, name: name, category: cat, isDirectory: isDir, detail: detail, caution: caution, enumeratorSize: size))
        }

        let fixed = fixedItems()
        for f in fixed { found.append(f); seenPaths.insert(f.path.path) }

        // Every path claimed by the fixed collectors. The walk must not
        // descend into these (or re-report their contents) or sizes would
        // be double-counted — e.g. ~/.cache/uv is listed as one item, so the
        // walk skips it instead of listing every wheel inside.
        let claimedPaths = Set(fixed.map { $0.path.path })

        func isClaimedOrInside(_ url: URL) -> Bool {
            var p = url
            while p.pathComponents.count > 1 {
                if claimedPaths.contains(p.path) { return true }
                p.deleteLastPathComponent()
            }
            return false
        }

        func isPrunedToolDir(_ url: URL) -> Bool {
            let path = url.path
            return walkPrunePrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        // ---- Project walk: build junk + large files ----
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            let rootDepth = root.pathComponents.count
            var walked = 0

            for case let url as URL in enumerator {
                walked += 1
                if walked % 1500 == 0 {
                    progress?(url.path.replacingOccurrences(of: home.path, with: "~"))
                }
                let depth = url.pathComponents.count - rootDepth
                let name = url.lastPathComponent
                let parent = url.deletingLastPathComponent()
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
                let isDir = values?.isDirectory ?? false
                let isPackage = values?.isPackage ?? false

                if isDir {
                    // Never descend into a subtree already claimed by a
                    // fixed collector — its size is already accounted for.
                    if isClaimedOrInside(url) { enumerator.skipDescendants(); continue }
                    // Tool-internal dirs aren't project space — skip them so
                    // bundled deps don't surface as bogus build artifacts.
                    if isPrunedToolDir(url) { enumerator.skipDescendants(); continue }
                    // Project build/dependency directories.
                    if specificNames.contains(name) {
                        add(url, name, .build, true, Descriptions.buildItem(name: name, parent: parent), name == ".venv" || name == "venv")
                        enumerator.skipDescendants()
                        continue
                    }
                    if genericNames.contains(name), parentHasManifest(parent) {
                        add(url, name, .build, true, Descriptions.buildItem(name: name, parent: parent), false)
                        enumerator.skipDescendants()
                        continue
                    }
                    // Pruning rules.
                    if isPackage || pruneNames.contains(name) { enumerator.skipDescendants(); continue }
                    if depth >= maxDepth { enumerator.skipDescendants(); continue }
                    if depth == 1 && parent == home {
                        // Library/Downloads/Applications are covered by the
                        // fixed collectors or listed per-child — skipping
                        // here avoids double-counting. Apps are never
                        // auto-cleaned. Music/Movies/Pictures are skipped to
                        // avoid TCC prompts. Other home dirs — including
                        // hidden tool dirs like ~/.vscode or ~/.cache — are
                        // walked so build output and huge files inside them
                        // are still found (unclaimed subtrees only).
                        if name == "Library" || name == "Downloads" || name == "Applications"
                            || name == "Music" || name == "Movies" || name == "Pictures" {
                            enumerator.skipDescendants(); continue
                        }
                    }
                } else {
                    // Large standalone files (not inside a found build dir — those were pruned).
                    let size = Int64(values?.fileSize ?? 0)
                    if size >= largeFileThreshold {
                        let (detail, caution) = Descriptions.generalItem(name: name, path: url, isDir: false)
                        add(url, name, .general, false, detail, caution, size)
                    }
                }
            }
        }
        return found
    }

    private func parentHasManifest(_ dir: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        for e in entries where manifestNames.contains(e) || e.hasSuffix(".csproj") || e.hasSuffix(".xcodeproj") {
            return true
        }
        return false
    }

    // MARK: - Fixed known locations

    private func fixedItems() -> [Found] {
        var items: [Found] = []
        let fm = FileManager.default

        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }
        func isDir(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true
        }
        func children(of dir: String, cat: Category, skipping skip: Set<String> = []) {
            guard let subs = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for s in subs where !s.hasPrefix(".") && !skip.contains(s) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(s)
                let dirFlag = isDir(url)
                let detail: String, caution: Bool
                if cat == .general {
                    (detail, caution) = Descriptions.generalItem(name: s, path: url, isDir: dirFlag)
                } else {
                    (detail, caution) = Descriptions.fixed(name: s, path: url)
                }
                // Files can't be du-measured later (enumeratorSize is used
                // for them), so capture the size now — otherwise they'd
                // all display as 0 bytes.
                var size: Int64 = 0
                if !dirFlag {
                    size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
                items.append(Found(path: url, name: s, category: cat, isDirectory: dirFlag, detail: detail, caution: caution, enumeratorSize: size))
            }
        }
        func single(_ path: String, cat: Category, name: String? = nil) {
            guard exists(path) else { return }
            let url = URL(fileURLWithPath: path)
            let (detail, caution) = Descriptions.fixed(name: name ?? url.lastPathComponent, path: url)
            items.append(Found(path: url, name: name ?? url.lastPathComponent, category: cat, isDirectory: true, detail: detail, caution: caution, enumeratorSize: 0))
        }

        let h = home.path

        // ---------- IDE & tool caches ----------
        children(of: "\(h)/Library/Developer/Xcode/DerivedData", cat: .caches)
        children(of: "\(h)/Library/Developer/CoreSimulator/Devices", cat: .caches)
        children(of: "\(h)/Library/Developer/CoreSimulator/Caches", cat: .caches)
        children(of: "\(h)/Library/Developer/Xcode/iOS DeviceSupport", cat: .caches)
        children(of: "\(h)/Library/Developer/Xcode/Archives", cat: .caches)
        children(of: "\(h)/Library/Caches/com.apple.dt.Xcode", cat: .caches)
        children(of: "\(h)/Library/Caches/Homebrew", cat: .caches)
        children(of: "\(h)/Library/Caches/org.swift.swiftpm", cat: .caches)
        single("\(h)/.npm", cat: .caches)
        children(of: "\(h)/Library/pnpm/store", cat: .caches)
        single("\(h)/.pnpm-store", cat: .caches)
        single("\(h)/Library/Caches/Yarn", cat: .caches)
        children(of: "\(h)/.yarn", cat: .caches)
        children(of: "\(h)/.bun/install/cache", cat: .caches)
        children(of: "\(h)/Library/Caches/deno", cat: .caches)
        children(of: "\(h)/Library/Caches/pip", cat: .caches)
        children(of: "\(h)/.cache/pip", cat: .caches)
        children(of: "\(h)/.gradle", cat: .caches)
        single("\(h)/.m2/repository", cat: .caches)
        children(of: "\(h)/.cargo/registry", cat: .caches)
        children(of: "\(h)/.cargo/git", cat: .caches)
        children(of: "\(h)/.rustup/toolchains", cat: .caches)
        children(of: "\(h)/.rustup/downloads", cat: .caches)
        single("\(h)/Library/Caches/go-build", cat: .caches)
        children(of: "\(h)/go/pkg/mod", cat: .caches)
        children(of: "\(h)/Library/Caches/CocoaPods", cat: .caches)
        children(of: "\(h)/.cocoapods", cat: .caches)
        children(of: "\(h)/Library/Caches/org.carthage.CarthageKit", cat: .caches)
        children(of: "\(h)/.tuist/Cache", cat: .caches)
        children(of: "\(h)/Library/Caches/JetBrains", cat: .caches)
        children(of: "\(h)/Library/Caches/dotnet", cat: .caches)
        children(of: "\(h)/.nuget/packages", cat: .caches)

        // Editor caches: VS Code + Cursor
        for editor in ["Code", "Cursor"] {
            let base = "\(h)/Library/Application Support/\(editor)"
            for sub in ["Cache", "CachedData", "Code Cache", "CachedExtensionVSIXs", "CachedProfilesData", "logs"] {
                single("\(base)/\(sub)", cat: .caches)
            }
            children(of: "\(base)/User/workspaceStorage", cat: .caches)
        }

        // Containerized dev environments (heavy, need care)
        children(of: "\(h)/Library/Containers/com.docker.docker/Data/vms", cat: .caches)
        single("\(h)/.orbstack/data", cat: .caches)
        children(of: "\(h)/.minikube", cat: .caches)

        // Language version managers
        children(of: "\(h)/.nvm/versions/node", cat: .caches)
        children(of: "\(h)/.pyenv/versions", cat: .caches)
        children(of: "\(h)/.rbenv/versions", cat: .caches)

        // Android
        children(of: "\(h)/.android/avd", cat: .caches)
        children(of: "\(h)/.android/cache", cat: .caches)

        // ---------- AI / ML ----------
        children(of: "\(h)/.ollama/models", cat: .ai)
        children(of: "\(h)/.cache/huggingface/hub", cat: .ai)
        children(of: "\(h)/.cache/huggingface/datasets", cat: .ai)
        children(of: "\(h)/.lmstudio/models", cat: .ai)
        children(of: "\(h)/.cache/lm-studio", cat: .ai)
        children(of: "\(h)/Library/Application Support/nomic.ai", cat: .ai)
        children(of: "\(h)/.cache/whisper", cat: .ai)
        children(of: "\(h)/.cache/torch", cat: .ai)
        children(of: "\(h)/.cache/torch_extensions", cat: .ai)

        // ---------- General ----------
        children(of: "\(h)/Downloads", cat: .general)
        children(of: "\(h)/.Trash", cat: .general)
        children(of: "\(h)/Library/Logs", cat: .general)
        // Skip cache dirs already listed individually under IDE & Tool Caches.
        children(of: "\(h)/Library/Caches", cat: .general, skipping: [
            "Homebrew", "com.apple.dt.Xcode", "org.swift.swiftpm", "Yarn", "deno",
            "pip", "go-build", "CocoaPods", "org.carthage.CarthageKit", "JetBrains",
            "dotnet",
        ])
        children(of: "\(h)/Library/Application Support/MobileSync/Backup", cat: .general)

        // ---------- Wider coverage: hidden tool dirs & app caches ----------

        // ~/.cache subtrees not already claimed above (uv, pkg, playwright,
        // gh, codex/devin/claude caches, …). Claimed subdirs are skipped so
        // nothing is double-counted.
        children(of: "\(h)/.cache", cat: .caches, skipping: [
            "huggingface", "lm-studio", "whisper", "torch", "torch_extensions", "pip",
        ])

        // Editor extension stores — reinstallable but often several GB.
        single("\(h)/.vscode/extensions", cat: .caches, name: "VS Code Extensions")
        single("\(h)/.cursor/extensions", cat: .caches, name: "Cursor Extensions")
        single("\(h)/.windsurf/extensions", cat: .caches, name: "Windsurf Extensions")

        // Alternate / extra package-manager stores.
        single("\(h)/.npm-cache", cat: .caches, name: "npm Cache")
        children(of: "\(h)/.gradle-home", cat: .caches)
        children(of: "\(h)/.gradle-local", cat: .caches)
        children(of: "\(h)/.pub-cache", cat: .caches)

        // Version managers & tool runtimes outside the classic dot-dirs.
        // Claiming them keeps the walk from flagging node_modules/venv
        // *inside* managed installs — those aren't project dependencies.
        children(of: "\(h)/.local/share/uv/python", cat: .caches)
        children(of: "\(h)/.local/share/uv/tools", cat: .caches)
        children(of: "\(h)/.local/share/fnm/node-versions", cat: .caches)
        children(of: "\(h)/.local/share/mise/installs", cat: .caches)
        children(of: "\(h)/.asdf/installs", cat: .caches)
        children(of: "\(h)/.volta/tools/image/node", cat: .caches)
        children(of: "\(h)/.volta/tools/image/packages", cat: .caches)
        children(of: "\(h)/.proto/tools", cat: .caches)
        children(of: "\(h)/.sdkman/candidates", cat: .caches)
        children(of: "\(h)/.nodenv/versions", cat: .caches)
        children(of: "\(h)/.jenv/versions", cat: .caches)
        children(of: "\(h)/.gem", cat: .caches)

        // Tool-internal caches that would otherwise surface as bogus
        // build artifacts when the walk reaches them.
        children(of: "\(h)/.codex/plugins", cat: .caches)
        single("\(h)/.codex/.tmp", cat: .caches, name: "Codex Temp Files")
        single("\(h)/.codex/cache", cat: .caches, name: "Codex Cache")
        single("\(h)/.composer/cache", cat: .caches, name: "Composer Cache")
        single("\(h)/.bun/install/global", cat: .caches, name: "Bun Global Packages")
        single("\(h)/Library/pnpm/global", cat: .caches, name: "pnpm Global Packages")

        // Website data & per-app HTTP storage (cookies — flagged for review).
        children(of: "\(h)/Library/WebKit", cat: .caches)
        children(of: "\(h)/Library/HTTPStorages", cat: .caches)

        // Cache-named folders inside app-data roots (Electron/Chromium
        // "Cache", "Code Cache", "GPUCache"…) and big sandboxed-app caches.
        items.append(contentsOf: appDataCacheItems())
        items.append(contentsOf: containerCacheItems())

        // The app-data scan can re-find paths the editor singles above
        // already claimed (e.g. "Code/Cache") — keep the first occurrence.
        var seen = Set<String>()
        return items.filter { seen.insert($0.path.path).inserted }
    }

    // MARK: - App-data & container cache discovery

    /// Directory names treated as pure caches when found inside app-data
    /// roots. Anything that holds real user state (IndexedDB, Local
    /// Storage, Session Storage, Service Worker…) is deliberately absent.
    private let appCacheDirNames: Set<String> = [
        "cache", "caches", "code cache", "gpucache", "cachedata", "cacheddata",
        "cachestorage", "cachedextensionvsixs", "cachedprofilesdata",
        "blob_storage", "crashpad", "logs", "log", "grshadercache",
        "graphitedawncache", "dawnwebgpucache", "dawngraphitecache",
    ]

    /// Sandboxed apps keep caches at <Container>/Data/Library/Caches. Only
    /// containers above this size are listed — the rest is noise.
    private let containerCacheMinSize: Int64 = 64 * 1024 * 1024

    /// Finds cache-named directories inside app-data roots — catches
    /// Electron/Chromium caches the fixed list can't know about, e.g.
    /// "Slack/Cache" or "Google/Chrome/Default/Code Cache".
    private func appDataCacheItems() -> [Found] {
        var items: [Found] = []
        for root in ["\(home.path)/Library/Application Support", "\(home.path)/Library/Group Containers"] {
            items.append(contentsOf: cacheDirs(under: root))
        }
        return items
    }

    private func cacheDirs(under root: String, maxDepth: Int = 3) -> [Found] {
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var items: [Found] = []
        for app in apps where !app.hasPrefix(".") && app != "MobileSync" {
            let appURL = URL(fileURLWithPath: root).appendingPathComponent(app)
            var appIsDir: ObjCBool = false
            guard fm.fileExists(atPath: appURL.path, isDirectory: &appIsDir), appIsDir.boolValue,
                  (try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { continue }
            var stack: [(url: URL, label: String, depth: Int)] = [(appURL, app, 0)]
            while let (dir, label, depth) = stack.popLast() {
                guard depth < maxDepth,
                      let subs = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for s in subs where !s.hasPrefix(".") {
                    let child = dir.appendingPathComponent(s)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue,
                          (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
                    else { continue }
                    if appCacheDirNames.contains(s.lowercased()) {
                        let (detail, caution) = Descriptions.fixed(name: s, path: child)
                        items.append(Found(path: child, name: "\(label)/\(s)", category: .caches,
                                           isDirectory: true, detail: detail, caution: caution,
                                           enumeratorSize: 0))
                    } else {
                        stack.append((child, "\(label)/\(s)", depth + 1))
                    }
                }
            }
        }
        return items
    }

    /// Sandboxed-app caches under ~/Library/Containers, pre-measured so
    /// only meaningful ones (≥ containerCacheMinSize) become items.
    private func containerCacheItems() -> [Found] {
        let dir = "\(home.path)/Library/Containers"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let targets = names.filter {
            !$0.hasPrefix(".") && !$0.contains("docker") && !$0.contains("orbstack")
        }
        var results = [Found?](repeating: nil, count: targets.count)
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let name = targets[i]
            let cache = "\(dir)/\(name)/Data/Library/Caches"
            var isDir: ObjCBool = false
            // Most container caches are empty — skip the du spawn for those.
            guard FileManager.default.fileExists(atPath: cache, isDirectory: &isDir), isDir.boolValue,
                  let subs = try? FileManager.default.contentsOfDirectory(atPath: cache), !subs.isEmpty
            else { return }
            let url = URL(fileURLWithPath: cache)
            let size = SizeMeasurer.measure(url, isDirectory: true)
            guard size >= containerCacheMinSize else { return }
            let (detail, caution) = Descriptions.fixed(name: name, path: url)
            results[i] = Found(path: url, name: "\(name) — Caches", category: .caches,
                               isDirectory: true, detail: detail, caution: caution,
                               enumeratorSize: 0)
        }
        return results.compactMap { $0 }
    }
}

// MARK: - Size measurement via /usr/bin/du (fast C implementation)

enum SizeMeasurer {
    static func measure(_ url: URL, isDirectory: Bool) -> Int64 {
        var args = ["-sk", "-x", url.path]
        if !isDirectory { args = ["-sk", url.path] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\t").first,
              let kb = Int64(line.trimmingCharacters(in: .whitespaces)) else { return 0 }
        return kb * 1024
    }
}
