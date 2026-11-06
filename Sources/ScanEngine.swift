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

    // Hidden home-directory folders already covered by the fixed collectors.
    private let homeDotSkip: Set<String> = [
        ".cache", ".npm", ".ollama", ".lmstudio", ".gradle", ".m2", ".cargo",
        ".rustup", ".docker", ".local", ".nvm", ".pyenv", ".rbenv", ".cocoapods",
        ".pub-cache", ".deno", ".bun", ".android", ".orbstack", ".vscode",
        ".cursor", ".gem", ".pulumi", ".dart", ".dotnet", ".expo", ".gradle",
        ".config", ".yarn", ".swiftpm", ".julia", ".conda", ".minikube",
    ]

    private let maxDepth = 8
    private let home = FileManager.default.homeDirectoryForCurrentUser

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

        for f in fixedItems() { found.append(f); seenPaths.insert(f.path.path) }

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
                        // Hidden home dirs are covered by the fixed collectors.
                        // Downloads/Trash children are listed individually under General —
                        // skipping here avoids double-counting. Apps are never auto-cleaned.
                        if homeDotSkip.contains(name) || name.hasPrefix(".")
                            || name == "Library" || name == "Downloads" || name == "Applications"
                            // TCC-protected media libraries — walking them triggers
                            // permission prompts and rarely finds build artifacts.
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
                items.append(Found(path: url, name: s, category: cat, isDirectory: dirFlag, detail: detail, caution: caution, enumeratorSize: 0))
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
            "dotnet", "CloudKit",
        ])
        children(of: "\(h)/Library/Application Support/MobileSync/Backup", cat: .general)

        return items
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
