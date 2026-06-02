import SSHAutoTunnelCore
import SwiftUI

struct MenuBarExtraStatusLabel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Image(systemName: appState.systemPACMenuBarBadgeSymbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(appState.systemPACStatusTint)
        }
        .accessibilityLabel("SSH AutoTunnel. \(appState.systemPACStatusTitle)")
    }
}

struct SystemPACStatusBadge: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Label {
            Text(appState.systemPACStatusTitle)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: appState.systemPACStatusSymbol)
                .foregroundStyle(appState.systemPACStatusTint)
        }
        .font(.caption.weight(.medium))
        .help(appState.systemPACStatusDetail)
    }
}

struct SystemPACStatusDetailView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(appState.systemPACStatusTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: appState.systemPACStatusSymbol)
                        .foregroundStyle(appState.systemPACStatusTint)
                }
                .font(.callout.weight(.medium))

                Spacer()

                Button {
                    appState.refreshSystemPACStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh System PAC status")

                Button {
                    appState.applySystemPAC()
                } label: {
                    Label("Reapply PAC", systemImage: "network")
                }
                .help("Apply PAC to the active network service")
            }

            Text(appState.systemPACStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

extension AppState {
    var systemPACMenuTitle: String {
        if networkDecision.shouldDisableProxy {
            return menuTitle(prefix: "PAC off: ", value: networkDecision.matchedRule?.name ?? activePACServiceName)
        }

        switch systemPACStatus.state {
        case .active:
            return menuTitle(prefix: "PAC active: ", value: activePACServiceName)
        case .staleAutoTunnelPAC:
            return menuTitle(prefix: "PAC refresh: ", value: activePACServiceName)
        case .notConfigured:
            if configuration.proxyApplyMode == .manual {
                return menuTitle(prefix: "PAC manual: ", value: activePACServiceName)
            }
            return menuTitle(prefix: "PAC missing: ", value: activePACServiceName)
        case .otherPAC:
            return menuTitle(prefix: "PAC other: ", value: activePACServiceName)
        case .unknown:
            return "PAC status unknown"
        }
    }

    var systemPACStatusTitle: String {
        if networkDecision.shouldDisableProxy {
            return "System PAC disabled by \(networkDecision.matchedRule?.name ?? "network rule")"
        }

        switch systemPACStatus.state {
        case .active:
            return "System PAC active on \(activePACServiceName)"
        case .staleAutoTunnelPAC:
            return "System PAC needs refresh on \(activePACServiceName)"
        case .notConfigured:
            return "System PAC not set on \(activePACServiceName)"
        case .otherPAC:
            return "Other PAC active on \(activePACServiceName)"
        case .unknown:
            return "System PAC status unknown"
        }
    }

    var systemPACStatusDetail: String {
        if networkDecision.shouldDisableProxy {
            return "Matched rule: \(networkDecision.matchedRule?.name ?? "unknown"). Active service: \(activePACServiceName)."
        }

        switch systemPACStatus.state {
        case .active:
            return "Active service \(activePACServiceName) uses \(systemPACStatus.expectedPACURL)."
        case .staleAutoTunnelPAC:
            return "Active service \(activePACServiceName) uses an older SSH AutoTunnel PAC URL: \(systemPACStatus.observedPACURL ?? "unknown")."
        case .notConfigured:
            if configuration.proxyApplyMode == .manual {
                return "Manual mode. Active service \(activePACServiceName) has no automatic proxy configuration."
            }
            return "Automatic mode is enabled, but active service \(activePACServiceName) has no automatic proxy configuration."
        case .otherPAC:
            return "Active service \(activePACServiceName) uses \(systemPACStatus.observedPACURL ?? "another PAC"). Expected \(systemPACStatus.expectedPACURL)."
        case .unknown:
            return systemPACStatus.errorMessage ?? "The active network service could not be inspected."
        }
    }

    var systemPACStatusSymbol: String {
        if networkDecision.shouldDisableProxy {
            return "slash.circle.fill"
        }

        switch systemPACStatus.state {
        case .active:
            return "checkmark.circle.fill"
        case .staleAutoTunnelPAC:
            return "arrow.clockwise.circle.fill"
        case .notConfigured:
            return configuration.proxyApplyMode == .manual ? "circle" : "exclamationmark.triangle.fill"
        case .otherPAC:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var systemPACMenuBarBadgeSymbol: String {
        if networkDecision.shouldDisableProxy {
            return "slash.circle"
        }

        switch systemPACStatus.state {
        case .active:
            return "checkmark.circle.fill"
        case .staleAutoTunnelPAC:
            return "arrow.clockwise.circle.fill"
        case .notConfigured:
            return configuration.proxyApplyMode == .manual ? "circle" : "exclamationmark.triangle.fill"
        case .otherPAC:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var systemPACStatusTint: Color {
        if networkDecision.shouldDisableProxy {
            return .secondary
        }

        switch systemPACStatus.state {
        case .active:
            return .green
        case .staleAutoTunnelPAC, .otherPAC:
            return .orange
        case .notConfigured:
            return configuration.proxyApplyMode == .manual ? .secondary : .orange
        case .unknown:
            return .yellow
        }
    }

    private var activePACServiceName: String {
        systemPACStatus.serviceName
            ?? currentNetworkFingerprint.serviceName
            ?? currentNetworkFingerprint.interfaceName
            ?? "active service"
    }

    private func menuTitle(prefix: String, value: String) -> String {
        let maxLength = 30
        let available = max(0, maxLength - prefix.count)
        return prefix + value.truncatedForMenu(maxLength: available)
    }
}

private extension String {
    func truncatedForMenu(maxLength: Int) -> String {
        guard maxLength > 3, count > maxLength else { return self }
        return String(prefix(maxLength - 3)) + "..."
    }
}
