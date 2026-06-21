import SSHAutoTunnelCore
import SwiftUI

struct PACRulesView: View {
    @EnvironmentObject private var appState: AppState

    private var ruleIDs: [UUID] {
        appState.configuration.pacRules.map(\.id)
    }

    private var shadowWarningsByRuleID: [UUID: PACRuleShadowWarning] {
        Dictionary(
            uniqueKeysWithValues: PACRuleShadowAnalyzer
                .warnings(configuration: appState.configuration)
                .map { ($0.ruleID, $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("PAC Routing")
                    .font(.title3)
                Spacer()
                Button {
                    addRule()
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .disabled(appState.configuration.profiles.isEmpty)
                .help("Add a PAC routing rule")
            }

            List {
                ForEach(ruleIDs, id: \.self) { ruleID in
                    PACRuleEditorRow(
                        ruleID: ruleID,
                        shadowWarning: shadowWarningsByRuleID[ruleID],
                        showsProfilePicker: true,
                        showsMoveControls: true,
                        onMoveUp: { moveRule(id: ruleID, by: -1) },
                        onMoveDown: { moveRule(id: ruleID, by: 1) },
                        onDelete: { deleteRule(id: ruleID) }
                    )
                    .environmentObject(appState)
                }
                .onMove(perform: moveRules)
                .onDelete(perform: deleteRules)
            }
            .onChange(of: appState.configuration.pacRules) {
                appState.scheduleConfigurationSave()
            }
        }
    }

    private func addRule() {
        if let profile = appState.configuration.profiles.first {
            appState.configuration.pacRules.append(PACRule(name: "New rule", domainPattern: "*.example.org", profileID: profile.id))
            appState.saveConfiguration()
        }
    }

    private func moveRules(from offsets: IndexSet, to destination: Int) {
        appState.configuration.pacRules.move(fromOffsets: offsets, toOffset: destination)
        appState.saveConfiguration()
    }

    private func moveRule(id ruleID: UUID, by distance: Int) {
        guard let index = appState.configuration.pacRules.firstIndex(where: { $0.id == ruleID }) else { return }
        let newIndex = index + distance
        guard appState.configuration.pacRules.indices.contains(newIndex) else { return }

        let rule = appState.configuration.pacRules.remove(at: index)
        appState.configuration.pacRules.insert(rule, at: newIndex)
        appState.saveConfiguration()
    }

    private func deleteRules(at offsets: IndexSet) {
        appState.configuration.pacRules.remove(atOffsets: offsets)
        appState.saveConfiguration()
    }

    private func deleteRule(id ruleID: UUID) {
        appState.configuration.pacRules.removeAll { $0.id == ruleID }
        appState.saveConfiguration()
    }
}

struct NetworkRulesView: View {
    @EnvironmentObject private var appState: AppState

    private var ruleIDs: [UUID] {
        appState.configuration.networkRules.map(\.id)
    }

    var body: some View {
        Form {
            Section("Current Decision") {
                Text(appState.networkDecision.shouldDisableProxy ? "Proxy disabled by network policy" : "Proxy allowed")
                if let rule = appState.networkDecision.matchedRule {
                    Text("Matched: \(rule.name)")
                        .foregroundStyle(.secondary)
                }
                if !appState.networkDecision.disabledProfileIDs.isEmpty {
                    Text("Disabled profiles: \(disabledProfileNames())")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Current Network") {
                NetworkFingerprintView(fingerprint: appState.currentNetworkFingerprint)
                Button("Create Disable Rule From Current Network") {
                    appState.addDisableRuleForCurrentNetwork()
                }
            }

            Section("Rules") {
                ForEach(ruleIDs, id: \.self) { ruleID in
                    NetworkRuleEditorDisclosure(
                        ruleID: ruleID,
                        showsScopePicker: true,
                        onDelete: { deleteRule(id: ruleID) }
                    )
                    .environmentObject(appState)
                }
                .onDelete(perform: deleteRules)

                Button("Add Network Rule") {
                    appState.configuration.networkRules.append(
                        NetworkPolicyRule(
                            name: "Trusted network",
                            match: NetworkMatch(searchDomainContains: "example.org"),
                            action: .disableProxy
                        )
                    )
                    appState.saveConfiguration()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.configuration.networkRules) {
            appState.scheduleConfigurationSave()
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        appState.configuration.networkRules.remove(atOffsets: offsets)
        appState.saveConfiguration()
    }

    private func deleteRule(id ruleID: UUID) {
        appState.configuration.networkRules.removeAll { $0.id == ruleID }
        appState.saveConfiguration()
    }

    private func disabledProfileNames() -> String {
        let names = appState.configuration.profiles
            .filter { appState.networkDecision.disabledProfileIDs.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? "unknown" : names.joined(separator: ", ")
    }
}

struct ProfileScopedRulesEditor: View {
    @EnvironmentObject private var appState: AppState
    let profile: TunnelProfile

    private var pacRuleIDs: [UUID] {
        appState.configuration.pacRules
            .filter { $0.profileID == profile.id }
            .map(\.id)
    }

    private var networkRuleIDs: [UUID] {
        appState.configuration.networkRules
            .filter { $0.profileID == profile.id }
            .map(\.id)
    }

    var body: some View {
        Section("PAC Rules for This Profile") {
            if pacRuleIDs.isEmpty {
                Text("No PAC rules reference this profile.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pacRuleIDs, id: \.self) { ruleID in
                    PACRuleEditorRow(
                        ruleID: ruleID,
                        shadowWarning: nil,
                        showsProfilePicker: false,
                        showsMoveControls: false,
                        onMoveUp: {},
                        onMoveDown: {},
                        onDelete: { deletePACRule(id: ruleID) }
                    )
                    .environmentObject(appState)
                }
            }

            Button {
                addPACRule()
            } label: {
                Label("Add PAC Rule", systemImage: "plus")
            }
        }

        Section("Network Rules for This Profile") {
            if networkRuleIDs.isEmpty {
                Text("No scoped network rules reference this profile.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(networkRuleIDs, id: \.self) { ruleID in
                    NetworkRuleEditorDisclosure(
                        ruleID: ruleID,
                        showsScopePicker: false,
                        onDelete: { deleteNetworkRule(id: ruleID) }
                    )
                    .environmentObject(appState)
                }
            }

            Button {
                addNetworkRule()
            } label: {
                Label("Add Network Rule", systemImage: "plus")
            }
        }
    }

    private func addPACRule() {
        appState.configuration.pacRules.append(
            PACRule(name: "\(profile.name) routing", domainPattern: "*.example.org", profileID: profile.id)
        )
        appState.saveConfiguration()
    }

    private func deletePACRule(id ruleID: UUID) {
        appState.configuration.pacRules.removeAll { $0.id == ruleID }
        appState.saveConfiguration()
    }

    private func addNetworkRule() {
        appState.configuration.networkRules.append(
            NetworkPolicyRule(
                name: "\(profile.name) trusted network",
                match: NetworkMatch(searchDomainContains: "example.org"),
                action: .disableProxy,
                profileID: profile.id
            )
        )
        appState.saveConfiguration()
    }

    private func deleteNetworkRule(id ruleID: UUID) {
        appState.configuration.networkRules.removeAll { $0.id == ruleID }
        appState.saveConfiguration()
    }
}

private struct PACRuleEditorRow: View {
    @EnvironmentObject private var appState: AppState
    var ruleID: UUID
    var shadowWarning: PACRuleShadowWarning?
    var showsProfilePicker: Bool
    var showsMoveControls: Bool
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void

    private var index: Int? {
        appState.configuration.pacRules.firstIndex { $0.id == ruleID }
    }

    var body: some View {
        if let index {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle("", isOn: $appState.configuration.pacRules[index].enabled)
                    .labelsHidden()
                    .frame(width: 22)

                if let shadowWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("This rule is shadowed by \(shadowWarning.shadowingRuleName), which appears earlier and matches first.")
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }

                if showsMoveControls {
                    iconButton(systemImage: "chevron.up", help: "Move rule up", disabled: index == appState.configuration.pacRules.startIndex) {
                        onMoveUp()
                    }
                    iconButton(
                        systemImage: "chevron.down",
                        help: "Move rule down",
                        disabled: index == appState.configuration.pacRules.index(before: appState.configuration.pacRules.endIndex)
                    ) {
                        onMoveDown()
                    }
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete rule", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete rule")

                TextField("Name", text: $appState.configuration.pacRules[index].name)
                    .frame(minWidth: 120)
                TextField("Domain pattern", text: $appState.configuration.pacRules[index].domainPattern)
                    .frame(minWidth: 150)
                if showsProfilePicker {
                    Picker("Profile", selection: $appState.configuration.pacRules[index].profileID) {
                        ForEach(appState.configuration.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .frame(minWidth: 140)
                }
                Picker("Failure", selection: $appState.configuration.pacRules[index].failureMode) {
                    ForEach(PACFailureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(width: 130)
            }
        }
    }

    private func iconButton(
        systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(help, systemImage: systemImage)
        }
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(Text(help))
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

private struct NetworkRuleEditorDisclosure: View {
    @EnvironmentObject private var appState: AppState
    var ruleID: UUID
    var showsScopePicker: Bool
    var onDelete: () -> Void

    private var index: Int? {
        appState.configuration.networkRules.firstIndex { $0.id == ruleID }
    }

    var body: some View {
        if let index {
            DisclosureGroup(appState.configuration.networkRules[index].name) {
                Toggle("Enabled", isOn: $appState.configuration.networkRules[index].enabled)
                TextField("Name", text: $appState.configuration.networkRules[index].name)
                if showsScopePicker {
                    Picker("Scope", selection: $appState.configuration.networkRules[index].profileID) {
                        Text("All profiles").tag(Optional<UUID>.none)
                        ForEach(appState.configuration.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                }
                TextField("Wi-Fi SSID", text: optionalRuleBinding($appState.configuration.networkRules[index].match.wifiSSID))
                TextField("Wi-Fi BSSID", text: optionalRuleBinding($appState.configuration.networkRules[index].match.wifiBSSID))
                TextField("Service contains", text: optionalRuleBinding($appState.configuration.networkRules[index].match.serviceNameContains))
                TextField("Search domain contains", text: optionalRuleBinding($appState.configuration.networkRules[index].match.searchDomainContains))
                TextField("Gateway", text: optionalRuleBinding($appState.configuration.networkRules[index].match.gateway))
                Picker("Action", selection: $appState.configuration.networkRules[index].action) {
                    ForEach(NetworkPolicyAction.allCases) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Network Rule", systemImage: "trash")
                }
            }
        }
    }
}

struct NetworkFingerprintView: View {
    var fingerprint: NetworkFingerprint

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            fingerprintRow("Service", fingerprint.serviceName)
            fingerprintRow("Interface", fingerprint.interfaceName)
            fingerprintRow("Wi-Fi SSID", fingerprint.wifiSSID)
            fingerprintRow("Wi-Fi BSSID", fingerprint.wifiBSSID)
            fingerprintRow("Gateway", fingerprint.gateway)
            fingerprintRow("Search domains", fingerprint.searchDomains.joined(separator: ", "))
            fingerprintRow("DNS servers", fingerprint.dnsServers.joined(separator: ", "))
            fingerprintRow("IPv4", fingerprint.ipv4Addresses.joined(separator: ", "))
            fingerprintRow("VPN interface", fingerprint.hasVPNInterface ? "yes" : "no")
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func fingerprintRow(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "-")
        }
    }
}

private func optionalRuleBinding(_ value: Binding<String?>) -> Binding<String> {
    Binding {
        value.wrappedValue ?? ""
    } set: { newValue in
        value.wrappedValue = newValue.isEmpty ? nil : newValue
    }
}
