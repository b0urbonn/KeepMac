import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
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
        .frame(width: 560, height: 440)
    }
}
