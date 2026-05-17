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
                Text("SSH Log")
                    .font(.headline)
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
            proxyDisabledByNetworkPolicy: appState.networkDecision.shouldDisableProxy
        )
        return PACGenerator.generate(context: context)
    }

    private func logPreview() -> String {
        guard let selectedProfileID else { return "Select a profile." }
        return appState.logs[selectedProfileID] ?? "No log output yet."
    }
}
