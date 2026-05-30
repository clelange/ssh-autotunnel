import AppKit
import SSHAutoTunnelCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(appState.configuration.profiles) { profile in
                let status = appState.status(for: profile)
                Button {
                    if status.health == .healthy || status.health == .connecting || status.health == .degraded {
                        appState.disconnect(profile)
                    } else {
                        appState.connect(profile)
                    }
                } label: {
                    Label(profile.name, systemImage: symbol(for: status.health))
                }
                .help(status.message)
            }

            if !appState.configuration.profiles.isEmpty {
                Menu {
                    ForEach(appState.configuration.profiles) { profile in
                        Button(profile.name) {
                            appState.connectInteractiveSSH(profile)
                        }
                    }
                } label: {
                    Label("Interactive SSH", systemImage: "terminal")
                }
            }

            Divider()

            Button {
                copy(appState.pacURL)
            } label: {
                Label("Copy PAC URL", systemImage: "doc.on.doc")
            }

            Button {
                appState.applySystemPAC()
            } label: {
                Label("Enable System PAC", systemImage: "network")
            }

            Button {
                appState.restoreSystemPAC()
            } label: {
                Label("Restore System Proxy", systemImage: "arrow.uturn.backward")
            }

            Divider()

            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                openWindow(id: "diagnostics")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Button {
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Setup", systemImage: "sparkles")
            }

            Divider()

            Text(appState.lastProxyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func symbol(for health: TunnelHealth) -> String {
        switch health {
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .unhealthy, .failed: "xmark.octagon.fill"
        case .stopped: "circle"
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
