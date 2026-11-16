import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var monitor: ProcessMonitor
    @EnvironmentObject var preferences: AppPreferences
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $preferences.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Open at login", isOn: Binding(get: { preferences.loginEnabled }, set: { preferences.setLoginEnabled($0) }))
                Text(preferences.loginMessage).font(.caption).foregroundStyle(.secondary)
                Button("Manage Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                Toggle("Scan storage on launch", isOn: $preferences.scanOnLaunch)
            }
            Section("Monitoring") {
                Picker("Refresh interval", selection: $monitor.refreshSeconds) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Toggle("Live monitoring", isOn: $monitor.autoRefresh)
                Text("Charts keep up to 10 minutes of samples in memory. CPU is the sum of process CPU percentages; 100% equals one core. Resident process memory may include shared pages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions & setup") {
                Button("Open Full Disk Access…") { preferences.openDiskAccess() }
                Button("Run setup again…") {
                    NSApp.keyWindow?.close()
                    openWindow(id: "main")
                    preferences.showSetup = true
                }
                Text("Enable KeepMac manually in macOS Privacy & Security for protected folders. No Accessibility or screen recording access is needed. macOS may request approval again after the app is moved or rebuilt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(store.roots, id: \.path) { url in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        Text((url.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .help(url.path)
                        Spacer()
                        if store.roots.count > 1 {
                            Button { store.removeRoot(url) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove folder from scan")
                            .accessibilityLabel("Remove \(url.lastPathComponent) from scan")
                        }
                    }
                }
                HStack {
                    Button { store.addRoot() } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    Spacer()
                    Button("Reset to Home Folder") { store.resetRoots() }
                }
            } header: {
                Text("Scan locations")
            } footer: {
                Text("Search these folders for build output, dependencies, virtual environments, and large files. Tool caches are also checked in their standard locations.")
            }

            Section {
                Stepper(value: $store.largeFileThresholdMB, in: 50...10_000, step: 50) {
                    HStack {
                        Text("Minimum file size")
                        Spacer()
                        Text("\(store.largeFileThresholdMB) MB")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Large files")
            } footer: {
                Text("Files above this size appear in Large & General. Changes take effect on your next scan.")
            }
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 620, height: 680)
        .preferredColorScheme(preferences.colorScheme)
        .onAppear { preferences.refreshLoginStatus() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { preferences.refreshLoginStatus() } }
        .onChange(of: monitor.autoRefresh) { _, enabled in enabled ? monitor.start() : monitor.stop() }
    }
}
