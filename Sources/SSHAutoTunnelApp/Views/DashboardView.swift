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
                DashboardSidebar(
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
        case .profile(let id):
            if let profile = appState.configuration.profiles.first(where: { $0.id == id }) {
                ProfileDetailPage(profile: profile) { deletedProfileID, _ in
                    if selection == .profile(deletedProfileID) {
                        selectNearestProfile(beforeDeleting: [deletedProfileID])
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
        let nextSelection = selectionAfterDeleting(ids: deletingIDs)
        let deletingIDSet = Set(deletingIDs)
        let offsets = IndexSet(appState.configuration.profiles.indices.filter { deletingIDSet.contains(appState.configuration.profiles[$0].id) })
        deleteCandidates = []
        guard !offsets.isEmpty else { return }

        selection = nextSelection
        appState.deleteProfiles(at: offsets, deleteKeychainItems: deleteKeychainItems)
    }

    private func selectionAfterDeleting(ids deletingIDs: [UUID]) -> DashboardSelection {
        guard case .profile(let selectedID) = selection else {
            return selection ?? .overview
        }

        guard Set(deletingIDs).contains(selectedID) else {
            return .profile(selectedID)
        }

        return nearestProfileIDAfterDeleting(ids: deletingIDs).map(DashboardSelection.profile) ?? .overview
    }

    private func nearestProfileIDAfterDeleting(ids deletingIDs: [UUID]) -> UUID? {
        let selectedProfileID: UUID?
        if case .profile(let selectedID) = selection {
            selectedProfileID = selectedID
        } else {
            selectedProfileID = nil
        }
        return ProfileDeletionSelectionPolicy.nearestRemainingProfileID(
            afterDeleting: deletingIDs,
            selectedProfileID: selectedProfileID,
            profiles: appState.configuration.profiles
        )
    }

    private func selectNearestProfile(beforeDeleting deletingIDs: [UUID]) {
        if let replacementID = nearestProfileIDAfterDeleting(ids: deletingIDs) {
            selection = .profile(replacementID)
        } else {
            selection = .overview
        }
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
    case profile(UUID)
}

private struct DashboardSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: DashboardSelection?
    var onDeleteProfile: (TunnelProfile) -> Void
    var onMoveProfile: (TunnelProfile, Int) -> Void

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
