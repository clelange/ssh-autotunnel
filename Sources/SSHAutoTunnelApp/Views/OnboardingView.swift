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
                OnboardingActionRow(
                    systemImage: "key",
                    title: "ssh-auto2fa presets",
                    detail: importMessage ?? "Use the existing CERN lxplus and PSI Tier-3 Keychain service names.",
                    buttonTitle: "Import",
                    action: importPresets
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
