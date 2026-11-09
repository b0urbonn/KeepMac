import SwiftUI

@main
struct KeepMacApp: App {
    @StateObject private var store = Store()
    @StateObject private var monitor = ProcessMonitor()

    var body: some Scene {
        Window("KeepMac", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(monitor)
                .frame(minWidth: 900, minHeight: 680)
                .task { store.rescan() }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { store.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.mode != .storage || store.scanning || store.deleting)
                Button("Clean All Safe…") { store.cleanAllSafe() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(store.mode != .storage || store.scanning || store.deleting)
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            Image(systemName: store.scanning ? "internaldrive.fill.badge.clock" : "internaldrive.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
