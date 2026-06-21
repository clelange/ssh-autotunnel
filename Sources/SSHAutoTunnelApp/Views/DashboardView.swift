import AppKit
import SSHAutoTunnelCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var selection: DashboardSelection? = .overview
    @State private var deleteCandidates: [TunnelProfile] = []

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Sidebar(
                    selection: $selection,
                    onDeleteProfile: { profile in
                        deleteCandidates = [profile]
                    },
                    onMoveProfile: moveProfile
                )
                .environmentObject(appState)

                Divider()
                profileControlBar
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            detail
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
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { !deleteCandidates.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        deleteCandidates = []
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                confirmDelete(deleteKeychainItems: false)
            }
            Button("Delete Profile and Keychain Items", role: .destructive) {
                confirmDelete(deleteKeychainItems: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keychain cleanup removes configured password and TOTP items only when no remaining profile references the same service and account.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewPage()
                .environmentObject(appState)
                .navigationTitle("Overview")
        case .allProfiles:
            ProfileCollectionPage(title: "All Profiles", profiles: appState.configuration.profiles)
                .environmentObject(appState)
                .navigationTitle("All Profiles")
        case .needsAttention:
            ProfileCollectionPage(title: "Needs Attention", profiles: attentionProfiles)
                .environmentObject(appState)
                .navigationTitle("Needs Attention")
        case .pacRules:
            PACRulesView()
                .environmentObject(appState)
                .navigationTitle("PAC Rules")
        case .networkRules:
            NetworkRulesView()
                .environmentObject(appState)
                .navigationTitle("Network Rules")
        case .tag(let tag):
            ProfileCollectionPage(title: tag, profiles: appState.configuration.profiles.filter { $0.tags.contains(tag) })
                .environmentObject(appState)
                .navigationTitle(tag)
        case .profile(let id):
            if let profile = appState.configuration.profiles.first(where: { $0.id == id }) {
                ProfileDetailPage(profile: profile) { deletedProfileID, originalIndex in
                    if selection == .profile(deletedProfileID) {
                        selectNearestProfile(afterDeletingFromOriginalIndex: originalIndex)
                    }
                }
                    .environmentObject(appState)
                    .navigationTitle(profile.name)
            } else {
                ContentUnavailableView("Profile Not Found", systemImage: "questionmark.folder")
            }
        }
    }

    private var selectedProfileIndex: Int? {
        guard case .profile(let id) = selection else { return nil }
        return appState.configuration.profiles.firstIndex { $0.id == id }
    }

    private var selectedProfile: TunnelProfile? {
        guard let selectedProfileIndex else { return nil }
        return appState.configuration.profiles[selectedProfileIndex]
    }

    private var canMoveSelectedProfileUp: Bool {
        guard let selectedProfileIndex else { return false }
        return selectedProfileIndex > 0
    }

    private var canMoveSelectedProfileDown: Bool {
        guard let selectedProfileIndex else { return false }
        return selectedProfileIndex < appState.configuration.profiles.count - 1
    }

    private var deleteConfirmationTitle: String {
        if deleteCandidates.count == 1, let profile = deleteCandidates.first {
            return "Delete \(profile.name)?"
        }
        return "Delete \(deleteCandidates.count) Profiles?"
    }

    private var profileControlBar: some View {
        HStack(spacing: 8) {
            Button {
                let profileID = appState.addGenericProfile()
                selection = .profile(profileID)
            } label: {
                Label("Add Profile", systemImage: "plus")
            }
            .help("Create a new profile")

            Button(role: .destructive) {
                if let selectedProfile {
                    deleteCandidates = [selectedProfile]
                }
            } label: {
                Label("Delete Profile", systemImage: "trash")
            }
            .disabled(selectedProfile == nil)
            .help("Delete the selected profile")

            Spacer()

            Button {
                moveSelectedProfile(by: -1)
            } label: {
                Label("Move Up", systemImage: "chevron.up")
            }
            .disabled(!canMoveSelectedProfileUp)
            .help("Move the selected profile up")

            Button {
                moveSelectedProfile(by: 1)
            } label: {
                Label("Move Down", systemImage: "chevron.down")
            }
            .disabled(!canMoveSelectedProfileDown)
            .help("Move the selected profile down")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var attentionProfiles: [TunnelProfile] {
        appState.configuration.profiles.filter { profile in
            let tunnel = appState.status(for: profile).health
            let hop = appState.hopStatus(for: profile)?.health
            return tunnel.needsAttention || hop?.needsAttention == true || appState.networkDecision.disabledProfileIDs.contains(profile.id)
        }
    }

    private func moveSelectedProfile(by distance: Int) {
        guard case .profile(let profileID) = selection,
              let index = selectedProfileIndex else {
            return
        }
        moveProfile(id: profileID, from: index, by: distance)
    }

    private func moveProfile(_ profile: TunnelProfile, by distance: Int) {
        guard let index = appState.configuration.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        moveProfile(id: profile.id, from: index, by: distance)
    }

    private func moveProfile(id profileID: UUID, from index: Int, by distance: Int) {
        let newIndex = index + distance
        guard appState.configuration.profiles.indices.contains(index),
              appState.configuration.profiles.indices.contains(newIndex) else {
            return
        }

        var profileIDs = appState.configuration.profiles.map(\.id)
        profileIDs.remove(at: index)
        profileIDs.insert(profileID, at: newIndex)
        appState.reorderProfiles(profileIDs: profileIDs)
        selection = .profile(profileID)
    }

    private func confirmDelete(deleteKeychainItems: Bool) {
        let deletingIDs = deleteCandidates.map(\.id)
        let nextSelection = nearestSelectionAfterDeleting(ids: deletingIDs)
        let deletingIDSet = Set(deletingIDs)
        let offsets = IndexSet(appState.configuration.profiles.indices.filter { deletingIDSet.contains(appState.configuration.profiles[$0].id) })
        deleteCandidates = []
        guard !offsets.isEmpty else { return }

        appState.deleteProfiles(at: offsets, deleteKeychainItems: deleteKeychainItems)
        selection = nextSelection.map(DashboardSelection.profile) ?? .overview
    }

    private func nearestSelectionAfterDeleting(ids deletingIDs: [UUID]) -> UUID? {
        let deletingIDSet = Set(deletingIDs)
        let profiles = appState.configuration.profiles
        if case .profile(let selectedID) = selection,
           !deletingIDSet.contains(selectedID),
           profiles.contains(where: { $0.id == selectedID }) {
            return selectedID
        }

        let targetIndex = deletingIDs.compactMap { id in profiles.firstIndex { $0.id == id } }.min()
        let remainingProfiles = profiles.enumerated().filter { !deletingIDSet.contains($0.element.id) }
        guard !remainingProfiles.isEmpty else { return nil }
        guard let targetIndex else { return remainingProfiles.first?.element.id }

        return remainingProfiles.first { $0.offset > targetIndex }?.element.id
            ?? remainingProfiles.last?.element.id
    }

    private func selectNearestProfile(afterDeletingFromOriginalIndex originalIndex: Int?) {
        guard !appState.configuration.profiles.isEmpty else {
            selection = .overview
            return
        }
        guard let originalIndex else {
            selection = .profile(appState.configuration.profiles[0].id)
            return
        }

        let replacementIndex = min(originalIndex, appState.configuration.profiles.count - 1)
        selection = .profile(appState.configuration.profiles[replacementIndex].id)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum DashboardSelection: Hashable {
    case overview
    case allProfiles
    case needsAttention
    case pacRules
    case networkRules
    case tag(String)
    case profile(UUID)
}

private struct Sidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: DashboardSelection?
    var onDeleteProfile: (TunnelProfile) -> Void
    var onMoveProfile: (TunnelProfile, Int) -> Void

    private var tags: [String] {
        Array(Set(appState.configuration.profiles.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var attentionCount: Int {
        appState.configuration.profiles.filter { profile in
            let tunnel = appState.status(for: profile).health
            let hop = appState.hopStatus(for: profile)?.health
            return tunnel.needsAttention || hop?.needsAttention == true || appState.networkDecision.disabledProfileIDs.contains(profile.id)
        }.count
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: DashboardSelection.overview) {
                    Label("Overview", systemImage: "rectangle.grid.2x2")
                }
                NavigationLink(value: DashboardSelection.allProfiles) {
                    CountedSidebarLabel(title: "All Profiles", count: appState.configuration.profiles.count, systemImage: "server.rack")
                }
                NavigationLink(value: DashboardSelection.needsAttention) {
                    CountedSidebarLabel(title: "Needs Attention", count: attentionCount, systemImage: "exclamationmark.triangle")
                }
                NavigationLink(value: DashboardSelection.pacRules) {
                    CountedSidebarLabel(title: "PAC Rules", count: appState.configuration.pacRules.count, systemImage: "point.3.connected.trianglepath.dotted")
                }
                NavigationLink(value: DashboardSelection.networkRules) {
                    CountedSidebarLabel(title: "Network Rules", count: appState.configuration.networkRules.count, systemImage: "wifi.router")
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in
                        NavigationLink(value: DashboardSelection.tag(tag)) {
                            CountedSidebarLabel(
                                title: tag,
                                count: appState.configuration.profiles.filter { $0.tags.contains(tag) }.count,
                                systemImage: "tag"
                            )
                        }
                    }
                }
            }

            Section("Profiles") {
                ForEach(appState.configuration.profiles) { profile in
                    NavigationLink(value: DashboardSelection.profile(profile.id)) {
                        SidebarProfileRow(profile: profile)
                            .environmentObject(appState)
                    }
                    .contextMenu {
                        Button {
                            appState.connect(profile)
                        } label: {
                            Label("Connect", systemImage: "play.fill")
                        }
                        Button {
                            appState.disconnect(profile)
                        } label: {
                            Label("Disconnect", systemImage: "stop.fill")
                        }
                        Button {
                            appState.connectInteractiveSSH(profile)
                        } label: {
                            Label("Interactive SSH", systemImage: "terminal")
                        }
                        Divider()
                        Button {
                            onMoveProfile(profile, -1)
                        } label: {
                            Label("Move Up", systemImage: "chevron.up")
                        }
                        Button {
                            onMoveProfile(profile, 1)
                        } label: {
                            Label("Move Down", systemImage: "chevron.down")
                        }
                        Divider()
                        Button(role: .destructive) {
                            onDeleteProfile(profile)
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("SSH AutoTunnel")
    }
}

private struct CountedSidebarLabel: View {
    var title: String
    var count: Int
    var systemImage: String

    var body: some View {
        Label {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private struct SidebarProfileRow: View {
    @EnvironmentObject private var appState: AppState
    let profile: TunnelProfile

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: appState.status(for: profile).health))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .lineLimit(1)
                Text(appState.status(for: profile).message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct OverviewPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

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
                InteractiveTerminalPreferenceControl(style: .dashboard)
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

private struct ProfileCollectionPage: View {
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
                    TagRow(tags: profile.tags)
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

private struct ProfileDetailPage: View {
    @EnvironmentObject private var appState: AppState
    let profile: TunnelProfile
    var onDelete: (UUID, Int?) -> Void

    private var tunnel: TunnelRuntimeStatus {
        appState.status(for: profile)
    }

    private var hop: HopRuntimeStatus? {
        appState.hopStatus(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 12)

            ProfileEditorView(
                profileID: profile.id,
                onDelete: onDelete,
                showsProfileRuleSections: true,
                showsRecentLog: true
            )
            .environmentObject(appState)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name)
                        .font(.title2.weight(.semibold))
                    Text(endpointSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    TagRow(tags: profile.tags)
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
        var parts = ["\(profile.sshDestination):\(profile.sshPort)"]
        if let interactiveHost = profile.interactiveHost?.trimmedNonEmpty {
            parts.append("interactive \(interactiveHost)")
        }
        parts.append("SOCKS 127.0.0.1:\(tunnel.effectiveLocalSocksPort ?? profile.localSocksPort)")
        if let jumpHost = profile.jumpHost?.trimmedNonEmpty {
            parts.append("via \(jumpHost)")
        }
        return parts.joined(separator: " | ")
    }

}

private struct SectionPanel<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        }
    }
}

private struct MetricTile: View {
    var title: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct KeyValueRow: Identifiable {
    var id = UUID()
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

private struct KeyValueGrid: View {
    var rows: [KeyValueRow]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.key)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 160, alignment: .leading)
                    Text(row.value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct StatusBadge: View {
    var label: String
    var health: TunnelHealth

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(for: health))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
            Text(health.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
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
                .frame(width: 52, alignment: .leading)
            StatusBadge(label: "", health: health)
                .frame(width: 112, alignment: .leading)
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

private struct ForwardingRow: View {
    var title: String
    var source: String
    var target: String
    var enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(enabled ? .green : .secondary)
                .frame(width: 18)
            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 120, alignment: .leading)
            Text(source)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(target)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}

private struct TagRow: View {
    var tags: [String]

    var body: some View {
        if tags.isEmpty {
            Text("No tags")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Label(tag, systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct InlineNotice: View {
    var title: String
    var message: String
    var systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

private struct FlowLayout<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) {
            content
        }
    }
}

private func statusColor(for health: TunnelHealth) -> Color {
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

private extension TunnelHealth {
    var isRunning: Bool {
        switch self {
        case .healthy, .connecting, .degraded, .reconnecting:
            true
        case .stopped, .unhealthy, .failed:
            false
        }
    }

    var needsAttention: Bool {
        switch self {
        case .unhealthy, .failed, .reconnecting:
            true
        case .stopped, .connecting, .healthy, .degraded:
            false
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
