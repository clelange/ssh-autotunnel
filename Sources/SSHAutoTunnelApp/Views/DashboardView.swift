import AppKit
import SSHAutoTunnelCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if appState.configuration.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Profiles", systemImage: "server.rack")
                    } actions: {
                        Button {
                            openWindow(id: "onboarding")
                            AppActivation.activate()
                        } label: {
                            Label("Setup", systemImage: "sparkles")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.configuration.profiles) { profile in
                            ProfileControlCard(profile: profile)
                                .environmentObject(appState)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    copy(appState.pacURL)
                } label: {
                    Label("Copy PAC URL", systemImage: "doc.on.doc")
                }
                .help("Copy the PAC URL")
                Button {
                    appState.toggleSystemPAC()
                } label: {
                    SystemPACToggleLabel()
                }
                .help(appState.systemPACToggleHelp)
            }
            ToolbarItemGroup {
                Button {
                    openWindow(id: "onboarding")
                    AppActivation.activate()
                } label: {
                    Label("Setup", systemImage: "sparkles")
                }
                .help("Open setup window")
                Button {
                    openWindow(id: "settings")
                    AppActivation.activate()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open settings")
                Button {
                    openWindow(id: "diagnostics")
                    AppActivation.activate()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .help("Open diagnostics")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH AutoTunnel")
                        .font(.title2.weight(.semibold))
                    SystemPACStatusBadge()
                    Text(appState.lastProxyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("PAC")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(appState.pacURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            InteractiveTerminalPreferenceControl(style: .dashboard)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct ProfileControlCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let profile: TunnelProfile

    private var tunnelStatus: TunnelRuntimeStatus {
        appState.status(for: profile)
    }

    private var hopStatus: HopRuntimeStatus? {
        appState.hopStatus(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.headline)
                    Text(endpointSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    if let hopStatus {
                        StatusBadge(label: "Hop", health: hopStatus.health)
                    }
                    StatusBadge(label: "Tunnel", health: tunnelStatus.health)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let hopStatus {
                    StatusLine(label: "Hop", health: hopStatus.health, message: hopStatus.message, pid: hopStatus.pid)
                }
                StatusLine(label: "Tunnel", health: tunnelStatus.health, message: tunnelStatus.message, pid: tunnelStatus.pid)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if hopStatus != nil {
                        Button {
                            if isActive(hopStatus?.health) {
                                appState.disconnectHop(profile)
                            } else {
                                appState.connectHop(profile)
                            }
                        } label: {
                            Label(isActive(hopStatus?.health) ? "Stop Hop" : "Start Hop", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .help(isActive(hopStatus?.health) ? "Stop the jump host tunnel" : "Start the jump host tunnel")
                    }

                    Button {
                        if isActive(tunnelStatus.health) {
                            appState.disconnect(profile)
                        } else {
                            appState.connect(profile)
                        }
                    } label: {
                        Label(isActive(tunnelStatus.health) ? "Stop Tunnel" : "Start Tunnel", systemImage: "arrow.left.arrow.right")
                    }
                    .help(isActive(tunnelStatus.health) ? "Stop the tunnel for this profile" : "Start the tunnel for this profile")

                    Button {
                        appState.reconnect(profile)
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .help("Reconnect this profile immediately")

                    Button {
                        appState.connectInteractiveSSH(profile)
                    } label: {
                        Label("Interactive SSH", systemImage: "terminal")
                    }
                    .help("Open an interactive SSH session for this profile")

                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        openDiagnostics()
                    } label: {
                        Label("View Log", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Open the captured SSH transcript for this profile")

                    if hopStatus != nil {
                        Button {
                            appState.connectHopWithVerboseSSHLogging(profileID: profile.id)
                            openDiagnostics()
                        } label: {
                            Label("Verbose Hop", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .help("Start the app-owned hop with verbose SSH diagnostics")
                    }

                    Button {
                        appState.connectWithVerboseSSHLogging(profileID: profile.id)
                        openDiagnostics()
                    } label: {
                        Label("Verbose Tunnel", systemImage: "terminal")
                    }
                    .help("Start the tunnel with verbose SSH diagnostics")

                    Spacer()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        }
    }

    private var endpointSummary: String {
        var parts = ["\(profile.sshDestination):\(profile.sshPort)", "SOCKS 127.0.0.1:\(profile.localSocksPort)"]
        if let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines), !jumpHost.isEmpty {
            parts.append("via \(jumpHost)")
        }
        return parts.joined(separator: " | ")
    }

    private func isActive(_ health: TunnelHealth?) -> Bool {
        switch health {
        case .healthy, .connecting, .degraded, .reconnecting:
            true
        case .stopped, .unhealthy, .failed, nil:
            false
        }
    }

    private func openDiagnostics() {
        appState.selectDiagnosticsProfile(profile.id)
        openWindow(id: "diagnostics")
        AppActivation.activate()
    }
}

private struct StatusBadge: View {
    var label: String
    var health: TunnelHealth

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: health))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
            Text(health.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func color(for health: TunnelHealth) -> Color {
        switch health {
        case .healthy:
            .green
        case .degraded, .connecting, .reconnecting:
            .orange
        case .unhealthy, .failed:
            .red
        case .stopped:
            .secondary
        }
    }
}

private struct StatusLine: View {
    var label: String
    var health: TunnelHealth
    var message: String
    var pid: Int32?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(health.rawValue.capitalized)
                .font(.caption)
                .frame(width: 82, alignment: .leading)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let pid {
                Text("PID \(pid)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
