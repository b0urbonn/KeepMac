import SwiftUI

@main
struct KeepMacApp: App {
    @StateObject private var store = Store()
    @StateObject private var monitor = ProcessMonitor()
    @StateObject private var preferences = AppPreferences()

    var body: some Scene {
        Window("KeepMac", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(monitor)
                .environmentObject(preferences)
                .preferredColorScheme(preferences.colorScheme)
                .frame(minWidth: 1000, minHeight: 700)
                .task {
                    preferences.refreshLoginStatus()
                    preferences.showSetup = !preferences.setupCompleted
                    if preferences.setupCompleted && preferences.scanOnLaunch { store.rescan() }
                    if monitor.autoRefresh { monitor.start() }
                }
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { store.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.scanning || store.deleting)
                Button("Clean All Safe…") { store.cleanAllSafe() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(store.scanning || store.deleting)
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
                .environmentObject(monitor)
        } label: {
            MenuBarStatusLabel(store: store, monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(monitor)
                .environmentObject(preferences)
        }
    }
}
