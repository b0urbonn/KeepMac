import SwiftUI
import ServiceManagement
import AppKit

@MainActor
final class AppPreferences: ObservableObject {
    @AppStorage("setupCompleted") var setupCompleted = false
    @AppStorage("scanOnLaunch") var scanOnLaunch = false
    @AppStorage("appearance") var appearance = "system"
    @Published var showSetup = false
    @Published var loginEnabled = false
    @Published var loginMessage = ""

    var colorScheme: ColorScheme? { appearance == "system" ? nil : appearance == "dark" ? .dark : .light }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        switch status {
        case .enabled: loginMessage = "KeepMac opens automatically when you log in."
        case .requiresApproval: loginMessage = "Approve KeepMac in System Settings → General → Login Items."
        case .notFound: loginMessage = "Install KeepMac in Applications before enabling login startup."
        default: loginMessage = "Login startup is off."
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            loginMessage = "Could not update login startup: \(error.localizedDescription)"
        }
    }

    func openDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var preferences: AppPreferences
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Set up your workstation", systemImage: "desktopcomputer")
                .font(.title2.bold())
            Text("Choose access and startup once. You can revisit these options in Settings.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("1. Install in Applications", systemImage: "folder")
                    .font(.headline)
                Text("Use the installed copy for permissions and login startup. Moving or rebuilding this ad-hoc signed app may require macOS approval again.")
                    .font(.callout).foregroundStyle(.secondary)
                Label("2. Allow disk access", systemImage: "lock.shield")
                    .font(.headline)
                Text("In Privacy & Security → Full Disk Access, add KeepMac and enable it. macOS controls this permission; KeepMac cannot grant it or reliably report its status. Restart the app after approval. Basic monitoring works without it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Full Disk Access") { preferences.openDiskAccess() }
                    Button("Reveal this app") { NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: "") }
                }
            }.consoleCard()
            Toggle("Open KeepMac when I log in", isOn: Binding(get: { preferences.loginEnabled }, set: { preferences.setLoginEnabled($0) }))
            Text(preferences.loginMessage).font(.caption).foregroundStyle(.secondary)
            Toggle("Scan storage automatically on launch", isOn: $preferences.scanOnLaunch)
            HStack {
                Text("No automatic deletion or process termination.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Finish setup") {
                    preferences.setupCompleted = true
                    preferences.showSetup = false
                    if preferences.scanOnLaunch { store.rescan() }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 590)
            .onAppear { preferences.refreshLoginStatus() }
    }
}
