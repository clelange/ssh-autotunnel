import SwiftUI

struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Form {
            Section("App Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(!updater.isEnabled || updater.startupError != nil)
                Text("Checks once a day. You choose when to download and install each update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                if let date = updater.lastCheckedAt {
                    Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !updater.isEnabled {
                    Text("In-app updates are available in official releases. This development build does not check for updates.")
                        .foregroundStyle(.secondary)
                }
                if let error = updater.startupError {
                    Text("Updates could not start: \(error)")
                        .foregroundStyle(.orange)
                }
            }
            Section("Installing an Update") {
                Text("Updates restart SSH AutoTunnel. If connections are active, the app asks before stopping them. You can cancel and install later.")
                Link("View Releases on GitHub", destination: URL(string: "https://github.com/clelange/ssh-autotunnel/releases/latest")!)
            }
        }
    }
}
