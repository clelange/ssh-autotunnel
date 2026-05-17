import AppKit
import SSHAutoTunnelCore
import SwiftUI

private let onboardingCompletedKey = "dev.clange.ssh-autotunnel.onboardingCompleted"

struct OnboardingPresenter: View {
    @AppStorage(onboardingCompletedKey) private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @State private var didPresent = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                presentIfNeeded()
            }
    }

    private func presentIfNeeded() {
        guard !hasCompletedOnboarding, !didPresent else { return }
        didPresent = true
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage(onboardingCompletedKey) private var hasCompletedOnboarding = false
    @State private var importMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("SSH AutoTunnel Setup", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                Text("Prepare the default tunnel profiles, PAC endpoint, and system proxy mode.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                SSHAuto2FAImportPanel(
                    statuses: appState.sshAuto2FAServiceStatuses,
                    importMessage: importMessage,
                    checkAction: appState.refreshSSHAuto2FAServiceStatuses,
                    importAction: importPresets
                )

                OnboardingActionRow(
                    systemImage: "gearshape",
                    title: "Profiles and PAC rules",
                    detail: "\(appState.configuration.profiles.count) profiles, \(appState.configuration.pacRules.count) PAC rules",
                    buttonTitle: "Settings"
                ) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }

                OnboardingActionRow(
                    systemImage: "network",
                    title: "PAC endpoint",
                    detail: appState.pacURL,
                    buttonTitle: "Copy"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.pacURL, forType: .string)
                }

                OnboardingActionRow(
                    systemImage: "stethoscope",
                    title: "Diagnostics",
                    detail: "Inspect tunnel state, logs, and local routing status.",
                    buttonTitle: "Open"
                ) {
                    openWindow(id: "diagnostics")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Spacer()

            HStack {
                Text(appState.lastProxyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Later") {
                    dismiss()
                }
                Button("Done") {
                    hasCompletedOnboarding = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 420)
    }

    private func importPresets() {
        let result = appState.importSSHAuto2FAPresets()
        importMessage = "\(result.createdProfiles) created, \(result.updatedProfiles) updated, \(result.createdPACRules) PAC rules added"
    }
}

private struct SSHAuto2FAImportPanel: View {
    var statuses: [SSHAuto2FAServiceStatus]
    var importMessage: String?
    var checkAction: () -> Void
    var importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ssh-auto2fa presets")
                        .font(.headline)
                    Text(importMessage ?? "CERN lxplus and PSI Tier-3 Keychain service names")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Check", action: checkAction)
                    .frame(width: 88)
                Button("Import", action: importAction)
                    .frame(width: 88)
            }

            if !statuses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(statuses) { status in
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: status.state))
                                .foregroundStyle(color(for: status.state))
                                .frame(width: 16)
                            Text(status.requirement.profileName)
                            Text(status.requirement.kind.displayName)
                                .foregroundStyle(.secondary)
                            Text(status.requirement.service)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Text(label(for: status.state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .padding(.leading, 34)
            }
        }
    }

    private func symbol(for state: KeychainCredentialState) -> String {
        switch state {
        case .available: "checkmark.circle.fill"
        case .missing: "questionmark.circle"
        case .unreadable: "exclamationmark.triangle.fill"
        }
    }

    private func color(for state: KeychainCredentialState) -> Color {
        switch state {
        case .available: .green
        case .missing: .secondary
        case .unreadable: .orange
        }
    }

    private func label(for state: KeychainCredentialState) -> String {
        switch state {
        case .available: "Found"
        case .missing: "Missing"
        case .unreadable: "Unreadable"
        }
    }
}

private struct OnboardingActionRow: View {
    var systemImage: String
    var title: String
    var detail: String
    var buttonTitle: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .frame(width: 88)
        }
    }
}
