import AppKit
import SSHAutoTunnelCore
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedProfileID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProfileID) {
                Section("Profiles") {
                    ForEach(appState.configuration.profiles) { profile in
                        let status = appState.status(for: profile)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(status.health.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(profile.id)
                    }
                }
                Section("PAC") {
                    Text(appState.pacURL)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generated PAC")
                    .font(.headline)
                ScrollView {
                    Text(currentPACPreview())
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Divider()
                HStack {
                    Text("SSH Log")
                        .font(.headline)
                    Spacer()
                    if let selectedProfileID {
                        Button {
                            appState.connectWithVerboseSSHLogging(profileID: selectedProfileID)
                        } label: {
                            Label("Verbose Connect", systemImage: "terminal")
                        }
                        Button {
                            copy(appState.fullSSHLog(for: selectedProfileID))
                        } label: {
                            Label("Copy Full Log", systemImage: "doc.on.doc")
                        }
                        Button {
                            revealLogFile(profileID: selectedProfileID)
                        } label: {
                            Label("Reveal File", systemImage: "folder")
                        }
                        Button(role: .destructive) {
                            appState.clearSSHLog(for: selectedProfileID)
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }
                }
                Text(logDetail())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                ScrollView {
                    Text(logPreview())
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .onAppear {
            selectedProfileID = selectedProfileID ?? appState.configuration.profiles.first?.id
        }
    }

    private func currentPACPreview() -> String {
        let context = PACGenerationContext(
            configuration: appState.configuration,
            statuses: appState.statuses,
            proxyDisabledByNetworkPolicy: appState.networkDecision.shouldDisableProxy,
            networkDisabledProfileIDs: appState.networkDecision.disabledProfileIDs
        )
        return PACGenerator.generate(context: context)
    }

    private func logPreview() -> String {
        guard let selectedProfileID else { return "Select a profile." }
        guard let preview = appState.logs[selectedProfileID], !preview.isEmpty else {
            return "No log output yet. Use Verbose Connect to run SSH with -vvv and capture detailed diagnostics."
        }
        return preview
    }

    private func logDetail() -> String {
        guard let selectedProfileID else {
            return "Select a profile to inspect SSH output."
        }
        guard let url = appState.sshLogURL(for: selectedProfileID) else {
            return "Full SSH log file is unavailable."
        }
        return "Preview shows the in-window tail. The full captured SSH transcript is written to \(url.path)."
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealLogFile(profileID: UUID) {
        guard let url = appState.sshLogURL(for: profileID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
