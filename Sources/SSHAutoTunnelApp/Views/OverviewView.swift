import SSHAutoTunnelCore
import SwiftUI

struct OverviewPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    var onCreateManualProfile: () -> Void = {}

    private var runningTunnels: Int {
        appState.configuration.profiles.filter { appState.status(for: $0).health.isRunning }.count
    }

    private var runningHops: Int {
        appState.configuration.profiles.compactMap { appState.hopStatus(for: $0) }.filter { $0.health.isRunning }.count
    }

    private var attentionProfiles: [TunnelProfile] {
        appState.configuration.profiles.filter { profile in
            let tunnel = appState.status(for: profile).health
            let hop = appState.hopStatus(for: profile)?.health
            return tunnel.needsAttention || hop?.needsAttention == true || appState.networkDecision.disabledProfileIDs.contains(profile.id)
        }
    }

    private var recentChanges: [ConnectionChange] {
        var changes: [ConnectionChange] = []
        for profile in appState.configuration.profiles {
            let tunnel = appState.status(for: profile)
            changes.append(ConnectionChange(profile: profile, kind: "Tunnel", health: tunnel.health, message: tunnel.message, changedAt: tunnel.lastChanged))
            if let hop = appState.hopStatus(for: profile) {
                changes.append(ConnectionChange(profile: profile, kind: "Hop", health: hop.health, message: hop.message, changedAt: hop.lastChanged))
            }
        }
        return changes.sorted { $0.changedAt > $1.changedAt }.prefix(8).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overviewHeader

                if appState.configuration.profiles.isEmpty {
                    FirstConnectionPanel(
                        createFromTemplate: {
                            openWindow(id: "connection-template-setup")
                            AppActivation.activate()
                        },
                        createManually: onCreateManualProfile,
                        openSettings: {
                            openWindow(id: "settings")
                            AppActivation.activate()
                        }
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Profiles", value: "\(appState.configuration.profiles.count)", detail: "\(runningTunnels) tunnels running")
                    MetricTile(title: "Hops", value: "\(runningHops)", detail: "App-owned jump connections")
                    MetricTile(title: "Needs Attention", value: "\(attentionProfiles.count)", detail: attentionProfiles.first?.name ?? "No active issues")
                    MetricTile(title: "System PAC", value: appState.systemPACStatus.state.rawValue, detail: appState.systemPACStatusTitle)
                }

                SectionPanel(title: "System PAC", systemImage: "network") {
                    SystemPACStatusDetailView()
                        .environmentObject(appState)
                    KeyValueGrid(rows: [
                        KeyValueRow("PAC URL", appState.pacURL),
                        KeyValueRow("Status URL", appState.statusURL),
                        KeyValueRow("Apply Mode", appState.configuration.proxyApplyMode.rawValue)
                    ])
                }

                SectionPanel(title: "Active Network", systemImage: "wifi") {
                    KeyValueGrid(rows: networkRows)
                    if appState.networkDecision.shouldDisableProxy {
                        InlineNotice(
                            title: "Proxy disabled",
                            message: appState.networkDecision.matchedRule?.name ?? "Matched network rule",
                            systemImage: "slash.circle"
                        )
                    }
                }

                SectionPanel(title: "Local Servers", systemImage: "point.3.connected.trianglepath.dotted") {
                    KeyValueGrid(rows: serverRows)
                }

                SectionPanel(title: "Recent Connection Changes", systemImage: "clock.arrow.circlepath") {
                    if recentChanges.isEmpty {
                        Text("No connection changes yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(recentChanges) { change in
                                ConnectionChangeRow(change: change)
                                if change.id != recentChanges.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SSH AutoTunnel")
                    .font(.title2.weight(.semibold))
                Text(appState.lastProxyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                InteractiveTerminalPreferenceControl()
                    .padding(.top, 2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    appState.connectAll()
                } label: {
                    Label("Connect All", systemImage: "play.fill")
                }
                Button {
                    appState.disconnectAll()
                } label: {
                    Label("Disconnect All", systemImage: "stop.fill")
                }
                Button {
                    openWindow(id: "diagnostics")
                    AppActivation.activate()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var networkRows: [KeyValueRow] {
        [
            KeyValueRow("Service", appState.currentNetworkFingerprint.serviceName ?? "Unknown"),
            KeyValueRow("Interface", appState.currentNetworkFingerprint.interfaceName ?? "Unknown"),
            KeyValueRow("Wi-Fi", appState.currentNetworkFingerprint.wifiSSID ?? "Unknown"),
            KeyValueRow("Gateway", appState.currentNetworkFingerprint.gateway ?? "Unknown"),
            KeyValueRow("Search Domains", appState.currentNetworkFingerprint.searchDomains.joined(separator: ", ").nilIfEmpty ?? "None"),
            KeyValueRow("VPN Interface", appState.currentNetworkFingerprint.hasVPNInterface ? "Detected" : "Not detected")
        ]
    }

    private var serverRows: [KeyValueRow] {
        let configured = LocalServerPorts(configuration: appState.configuration)
        let active = appState.activeServerPorts
        return [
            KeyValueRow("PAC HTTP", "\(active?.pacHTTPPort ?? configured.pacHTTPPort)"),
            KeyValueRow("Local API", "\(active?.apiHTTPPort ?? configured.apiHTTPPort)"),
            KeyValueRow("Blocking Proxy", "\(active?.blockingHTTPProxyPort ?? configured.blockingHTTPProxyPort)")
        ]
    }
}

private struct FirstConnectionPanel: View {
    var createFromTemplate: () -> Void
    var createManually: () -> Void
    var openSettings: () -> Void

    var body: some View {
        SectionPanel(title: "No Profiles", systemImage: "server.rack") {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create the first SSH connection.")
                        .font(.callout.weight(.medium))
                    Text("Use a built-in template, start from a blank profile, or open settings for imports.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button {
                        createFromTemplate()
                    } label: {
                        Label("Create from Template", systemImage: "list.bullet.rectangle")
                    }
                    .keyboardShortcut("n", modifiers: [.command])

                    Button {
                        createManually()
                    } label: {
                        Label("Create Manually", systemImage: "plus")
                    }

                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct ProfileCollectionPage: View {
    @EnvironmentObject private var appState: AppState
    var title: String
    var profiles: [TunnelProfile]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(profiles.count) profiles")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if profiles.isEmpty {
                    ContentUnavailableView("No Profiles", systemImage: "server.rack")
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    VStack(spacing: 10) {
                        ForEach(profiles) { profile in
                            ProfileSummaryPanel(profile: profile)
                                .environmentObject(appState)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProfileSummaryPanel: View {
    @EnvironmentObject private var appState: AppState
    let profile: TunnelProfile

    private var tunnel: TunnelRuntimeStatus {
        appState.status(for: profile)
    }

    private var hop: HopRuntimeStatus? {
        appState.hopStatus(for: profile)
    }

    var body: some View {
        SectionPanel(title: profile.name, systemImage: "server.rack") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(endpointSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    if let hop {
                        StatusBadge(label: "Hop", health: hop.health)
                    }
                    StatusBadge(label: "Tunnel", health: tunnel.health)
                }
            }
        }
    }

    private var endpointSummary: String {
        let socksPort = tunnel.effectiveLocalSocksPort ?? profile.localSocksPort
        var parts = ["\(profile.sshDestination):\(profile.sshPort)", "SOCKS 127.0.0.1:\(socksPort)"]
        if let jumpHost = profile.jumpHost?.trimmedNonEmpty {
            parts.append("via \(jumpHost)")
        }
        return parts.joined(separator: " | ")
    }
}

private struct ConnectionChange: Identifiable, Equatable {
    var id = UUID()
    var profile: TunnelProfile
    var kind: String
    var health: TunnelHealth
    var message: String
    var changedAt: Date
}

private struct ConnectionChangeRow: View {
    var change: ConnectionChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(statusColor(for: change.health))
                .frame(width: 8, height: 8)
            Text(change.profile.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(change.kind)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(change.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(change.changedAt, style: .relative)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }
}
