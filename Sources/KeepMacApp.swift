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
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
