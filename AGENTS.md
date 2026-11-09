# KeepMac

Native SwiftUI macOS storage-cleaner for developers. Builds with Command Line
Tools only — **no Xcode required**.

## Build

```bash
./build.sh   # → dist/KeepMac.app and dist/KeepMac-1.0.dmg
```

Compiles `Sources/*.swift` with `swiftc -target arm64-apple-macosx26.0`,
bundles the .app manually, ad-hoc signs, packages a DMG via `hdiutil`.

## Constraints

- **No `@State`**: `State` is a macro (`SwiftUIMacros`) and that plugin only
  ships inside Xcode.app, not the CLT. It will not compile here. Keep view
  state in `@Published` properties on `Store`/other `ObservableObject`s and
  bind via `$store.prop`. `Binding`, `StateObject`, `ObservedObject`,
  `EnvironmentObject`, `Environment`, `AppStorage`, `Published`, `FocusState`
  are all still real property wrappers — safe to use.
- **FoundationModels** (Apple Intelligence) is in the CLT SDK and works:
  `SystemLanguageModel.default.availability`, `LanguageModelSession`.
- Signing is ad-hoc; the app is unsigned for Gatekeeper but runs locally
  without quarantine prompts.
- **Window scene, not WindowGroup**: a `WindowGroup` gets the macOS tab bar
  (stray gray bar + "+" button under the titlebar). `Window` + a
  `NSViewRepresentable` that sets `window.tabbingMode = .disallowed`
  (`WindowConfigurator` in ContentView.swift) removes it.
- **TCC prompts**: scanning home triggers one-time privacy prompts for
  Documents/Desktop/Downloads and Media Library (MobileSync backups).
  Usage strings live in Info.plist; `~/Music`, `~/Movies`, `~/Pictures`
  are skipped in the walk to avoid pointless prompts.
- **Menu bar**: a `MenuBarExtra` (`.window` style) lives alongside the main
  `Window` scene — the app keeps its Dock icon. `MenuBarPanel.swift` reads
  the same `Store`; "Clean All Safe…" calls `openWindow(id: "main")` then
  `store.cleanAllSafe()`, which works because the delete-confirm sheet is
  bound to `store.showDeleteConfirm` and presents on appear.
- **Scan coverage invariant**: every path returned by `fixedItems()` is in
  `claimedPaths`, and the project walk skips any directory equal to or
  inside a claimed path (`isClaimedOrInside`). When adding collectors,
  always go through `children`/`single`/`Found` inside `fixedItems()` —
  never let the walk and a collector claim overlapping trees or sizes
  double-count. Hidden home dirs (dot-dirs) ARE walked now; only
  Library/Downloads/Applications/media are skipped at depth 1.

## Layout

- `Sources/ScanEngine.swift` — directory walk + fixed-path collectors, sizes
  via `/usr/bin/du -sk -x` (concurrency limited in `Store.rescan`)
- `Sources/Models.swift` — categories, item model, built-in descriptions
- `Sources/Store.swift` — scan/delete orchestration, settings
- `Sources/Explainer.swift` — Apple Intelligence "explain this item"
- `Sources/ContentView.swift`, `SettingsView.swift`, `KeepMacApp.swift` — UI
- `Sources/MenuBarPanel.swift` — menu-bar extra panel (status, top items,
  Rescan / Clean All Safe / Open / Quit)
- `Tools/gen_icon.swift` — renders the app icon (AppKit, no assets needed)
