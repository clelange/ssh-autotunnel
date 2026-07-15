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
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    @State private var presentsDirectNetworkSheet = false

    private var directRuleIDs: [UUID] {
        appState.configuration.networkRules.filter { $0.action == .directAccess }.map(\.id)
    }

    private var legacyRuleIDs: [UUID] {
        appState.configuration.networkRules.filter { $0.action != .directAccess }.map(\.id)
    }

    var body: some View {
        Form {
            Section("Current Behavior") {
                if appState.networkDecision.directAccessProfileIDs.isEmpty {
                    Label("No direct-network policy is active", systemImage: "network")
                } else {
                    Label("Using direct access on this network", systemImage: "point.3.connected.trianglepath.dotted")
                    Text("Paused profiles: \(directAccessProfileNames())")
                        .foregroundStyle(.secondary)
                }
                ForEach(appState.networkDecision.matchedDirectAccessRules) { rule in
                    Text("Matched: \(rule.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let rule = appState.networkDecision.matchedRule {
                    Text("Legacy routing policy matched: \(rule.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !appState.networkDecision.disabledProfileIDs.isEmpty {
                    Text("Legacy PAC bypass: \(disabledProfileNames())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Current Network") {
                NetworkFingerprintView(fingerprint: appState.currentNetworkFingerprint)
                Text(currentConnectionExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Use Direct Access on This Network…") {
                    presentsDirectNetworkSheet = true
                }
                .disabled(appState.configuration.profiles.isEmpty)
            }

            Section {
                if directRuleIDs.isEmpty {
                    Text("No direct networks configured.")
                        .foregroundStyle(.secondary)
                }
                ForEach(directRuleIDs, id: \.self) { ruleID in
                    NetworkRuleEditorDisclosure(
                        ruleID: ruleID,
                        showsScopePicker: true,
                        onDelete: { deleteRule(id: ruleID) }
                    )
                    .environmentObject(appState)
                }
                Button("Add Direct Network…") {
                    presentsDirectNetworkSheet = true
                }
            } header: {
                Text("Direct Networks")
            } footer: {
                Text("When matched, affected tunnels and app-owned hop usage stop, PAC traffic uses the normal fallback, and Interactive SSH connects directly. Network-provided identifiers are convenience signals, not authentication.")
            }

            if !legacyRuleIDs.isEmpty {
                Section {
                    ForEach(legacyRuleIDs, id: \.self) { ruleID in
                        NetworkRuleEditorDisclosure(
                            ruleID: ruleID,
                            showsScopePicker: true,
                            onDelete: { deleteRule(id: ruleID) }
                        )
                        .environmentObject(appState)
                    }
                } header: {
                    Text("Legacy Routing Policies")
                } footer: {
                    Text("Legacy Disable/Allow Proxy policies affect PAC routing only. If several identifiers are filled in, all of them must match.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.configuration.networkRules) {
            appState.scheduleConfigurationSave()
        }
        .sheet(isPresented: $presentsDirectNetworkSheet) {
            DirectNetworkCreationSheet(
                fingerprint: appState.currentNetworkFingerprint,
                initialProfileID: appState.configuration.profiles.first?.id
            )
            .environmentObject(appState)
        }
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

    private func directAccessProfileNames() -> String {
        let names = appState.configuration.profiles
            .filter { appState.networkDecision.directAccessProfileIDs.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? "unknown" : names.joined(separator: ", ")
    }

    private var currentConnectionExplanation: String {
        if let ssid = appState.currentNetworkFingerprint.wifiSSID, !ssid.isEmpty {
            return "Wi-Fi network \(ssid). DNS search-domain policies also work when the same organization is reached over Ethernet or VPN."
        }
        return "No Wi-Fi SSID is present. On Ethernet, use a DNS search domain when available; the gateway is an advanced alternative."
    }
}

private struct DirectNetworkCreationSheet: View {
    private enum SignalKind: String, CaseIterable, Identifiable {
        case searchDomain
        case wifiSSID
        case gateway

        var id: String { rawValue }

        var label: String {
            switch self {
            case .searchDomain: "DNS search domain"
            case .wifiSSID: "Wi-Fi SSID"
            case .gateway: "Gateway"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    private let locksProfile: Bool
    @State private var name: String
    @State private var profileID: UUID?
    @State private var signalKind: SignalKind
    @State private var searchDomain: String
    @State private var wifiSSID: String
    @State private var gateway: String
    @State private var errorMessage: String?

    init(fingerprint: NetworkFingerprint, initialProfileID: UUID?, locksProfile: Bool = false) {
        let searchDomain = fingerprint.searchDomains.first ?? ""
        let wifiSSID = fingerprint.wifiSSID ?? ""
        let gateway = fingerprint.gateway ?? ""
        let signalKind: SignalKind = !searchDomain.isEmpty ? .searchDomain : (!wifiSSID.isEmpty ? .wifiSSID : .gateway)
        let signalName = !searchDomain.isEmpty ? searchDomain : (!wifiSSID.isEmpty ? wifiSSID : gateway)
        _name = State(initialValue: signalName.isEmpty ? "Direct network" : "Direct access: \(signalName)")
        _profileID = State(initialValue: initialProfileID)
        _signalKind = State(initialValue: signalKind)
        _searchDomain = State(initialValue: searchDomain)
        _wifiSSID = State(initialValue: wifiSSID)
        _gateway = State(initialValue: gateway)
        self.locksProfile = locksProfile
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Policy") {
                    TextField("Name", text: $name)
                    Picker("Apply to", selection: $profileID) {
                        Text("All profiles").tag(Optional<UUID>.none)
                        ForEach(appState.configuration.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    .disabled(locksProfile)
                }

                Section {
                    Picker("Identify by", selection: $signalKind) {
                        ForEach(SignalKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    switch signalKind {
                    case .searchDomain:
                        TextField("Domain", text: $searchDomain)
                        Text("Matches this DNS search domain or a real subdomain, regardless of Wi-Fi, Ethernet, or VPN transport.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .wifiSSID:
                        TextField("Wi-Fi SSID", text: $wifiSSID)
                        Text("Wi-Fi only. This policy cannot match a wired connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .gateway:
                        TextField("Gateway", text: $gateway)
                        Text("Advanced: gateway addresses can be reused by unrelated networks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Network Identifier")
                } footer: {
                    Text("Network identifiers can be supplied by the local network. Use this only to select a direct route on networks you trust.")
                }

                Section("Behavior") {
                    Text("The selected connection stops while this policy matches, its PAC routes use the normal fallback, and Interactive SSH skips its jump host. Previous tunnel intent resumes when the network changes.")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Direct Network")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addRule() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedValue.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 470)
    }

    private var selectedValue: String {
        let value: String
        switch signalKind {
        case .searchDomain: value = searchDomain
        case .wifiSSID: value = wifiSSID
        case .gateway: value = gateway
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addRule() {
        let match: NetworkMatch
        switch signalKind {
        case .searchDomain:
            match = NetworkMatch(searchDomainSuffix: selectedValue)
        case .wifiSSID:
            match = NetworkMatch(wifiSSID: selectedValue)
        case .gateway:
            match = NetworkMatch(gateway: selectedValue)
        }
        let rule = NetworkPolicyRule(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            match: match,
            action: .directAccess,
            profileID: profileID
        )
        do {
            appState.configuration = try NetworkRuleConfigurationEditor.create(rule: rule, in: appState.configuration)
            appState.saveConfiguration()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ProfileScopedRulesEditor: View {
    @EnvironmentObject private var appState: AppState
    @State private var presentsDirectNetworkSheet = false
    let profile: TunnelProfile

    private var pacRuleIDs: [UUID] {
        appState.configuration.pacRules
            .filter { $0.profileID == profile.id }
            .map(\.id)
    }

    private var directNetworkRuleIDs: [UUID] {
        appState.configuration.networkRules
            .filter { $0.profileID == profile.id && $0.action == .directAccess }
            .map(\.id)
    }

    private var legacyNetworkRuleIDs: [UUID] {
        appState.configuration.networkRules
            .filter { $0.profileID == profile.id && $0.action != .directAccess }
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

        Section("Direct Networks for This Profile") {
            if directNetworkRuleIDs.isEmpty {
                Text("No direct networks configured for this profile.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(directNetworkRuleIDs, id: \.self) { ruleID in
                    NetworkRuleEditorDisclosure(
                        ruleID: ruleID,
                        showsScopePicker: false,
                        onDelete: { deleteNetworkRule(id: ruleID) }
                    )
                    .environmentObject(appState)
                }
            }

            Button {
                presentsDirectNetworkSheet = true
            } label: {
                Label("Add Direct Network…", systemImage: "plus")
            }
        }

        if !legacyNetworkRuleIDs.isEmpty {
            Section("Legacy Routing Policies for This Profile") {
                ForEach(legacyNetworkRuleIDs, id: \.self) { ruleID in
                    NetworkRuleEditorDisclosure(
                        ruleID: ruleID,
                        showsScopePicker: false,
                        onDelete: { deleteNetworkRule(id: ruleID) }
                    )
                    .environmentObject(appState)
                }
            }
        }
        Color.clear
            .frame(height: 0)
            .sheet(isPresented: $presentsDirectNetworkSheet) {
                DirectNetworkCreationSheet(
                    fingerprint: appState.currentNetworkFingerprint,
                    initialProfileID: profile.id,
                    locksProfile: true
                )
                .environmentObject(appState)
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
            HStack(alignment: .top, spacing: 8) {
                ruleControls(index: index)
                    .padding(.top, 18)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        nameField(index: index)
                        domainPatternField(index: index)
                        if showsProfilePicker {
                            profileField(index: index)
                        }
                        failureField(index: index)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            nameField(index: index)
                            domainPatternField(index: index)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            if showsProfilePicker {
                                profileField(index: index)
                            }
                            failureField(index: index)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ruleControls(index: Int) -> some View {
        HStack(spacing: 8) {
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
        }
    }

    private func nameField(index: Int) -> some View {
        CompactConfigurationField(title: "Name") {
            TextField("Name", text: $appState.configuration.pacRules[index].name)
                .labelsHidden()
                .accessibilityLabel("Name")
        }
        .frame(minWidth: 120, idealWidth: 150)
    }

    private func domainPatternField(index: Int) -> some View {
        CompactConfigurationField(title: "Domain pattern") {
            TextField("Domain pattern", text: $appState.configuration.pacRules[index].domainPattern)
                .labelsHidden()
                .accessibilityLabel("Domain pattern")
        }
        .frame(minWidth: 150, idealWidth: 220)
        .layoutPriority(1)
    }

    private func profileField(index: Int) -> some View {
        CompactConfigurationField(title: "Profile") {
            Picker("Profile", selection: $appState.configuration.pacRules[index].profileID) {
                ForEach(appState.configuration.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Profile")
        }
        .frame(minWidth: 140, idealWidth: 160)
    }

    private func failureField(index: Int) -> some View {
        CompactConfigurationField(title: "Failure") {
            Picker("Failure", selection: $appState.configuration.pacRules[index].failureMode) {
                ForEach(PACFailureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Failure")
        }
        .frame(width: 130)
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
                if appState.configuration.networkRules[index].action == .directAccess {
                    TextField("Search domain or subdomain", text: optionalRuleBinding($appState.configuration.networkRules[index].match.searchDomainSuffix))
                    DisclosureGroup("Advanced identifiers") {
                        TextField("Wi-Fi SSID", text: optionalRuleBinding($appState.configuration.networkRules[index].match.wifiSSID))
                        TextField("Wi-Fi BSSID", text: optionalRuleBinding($appState.configuration.networkRules[index].match.wifiBSSID))
                        TextField("Service contains", text: optionalRuleBinding($appState.configuration.networkRules[index].match.serviceNameContains))
                        TextField("Gateway", text: optionalRuleBinding($appState.configuration.networkRules[index].match.gateway))
                    }
                    LabeledContent("Behavior", value: "Pause connection and use direct access")
                } else {
                    TextField("Wi-Fi SSID", text: optionalRuleBinding($appState.configuration.networkRules[index].match.wifiSSID))
                    TextField("Wi-Fi BSSID", text: optionalRuleBinding($appState.configuration.networkRules[index].match.wifiBSSID))
                    TextField("Service contains", text: optionalRuleBinding($appState.configuration.networkRules[index].match.serviceNameContains))
                    TextField("Legacy search domain contains", text: optionalRuleBinding($appState.configuration.networkRules[index].match.searchDomainContains))
                    TextField("Gateway", text: optionalRuleBinding($appState.configuration.networkRules[index].match.gateway))
                    Picker("Legacy action", selection: $appState.configuration.networkRules[index].action) {
                        Text("Disable proxy routing").tag(NetworkPolicyAction.disableProxy)
                        Text("Allow proxy routing").tag(NetworkPolicyAction.allowProxy)
                    }
                }
                if conditionCount(appState.configuration.networkRules[index].match) > 1 {
                    Label("All configured identifiers must match (AND).", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isWiFiOnly(appState.configuration.networkRules[index].match) {
                    Label("Wi-Fi only; this cannot match Ethernet.", systemImage: "wifi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Network Rule", systemImage: "trash")
                }
            }
        }
    }

    private func conditionCount(_ match: NetworkMatch) -> Int {
        [
            match.wifiSSID,
            match.wifiBSSID,
            match.serviceNameContains,
            match.searchDomainContains,
            match.searchDomainSuffix,
            match.gateway
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? $0 : nil }.count
            + (match.vpnRequired == nil ? 0 : 1)
    }

    private func isWiFiOnly(_ match: NetworkMatch) -> Bool {
        (match.wifiSSID?.isEmpty == false || match.wifiBSSID?.isEmpty == false)
            && match.serviceNameContains?.isEmpty != false
            && match.searchDomainContains?.isEmpty != false
            && match.searchDomainSuffix?.isEmpty != false
            && match.gateway?.isEmpty != false
            && match.vpnRequired == nil
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
