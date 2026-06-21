import AppKit
import SSHAutoTunnelCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            AppPreferencesView()
                .tabItem { Label("App", systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 620)
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let profileID: UUID
    var onDelete: (UUID, Int?) -> Void = { _, _ in }
    var showsProfileRuleSections = false
    var showsRecentLog = false
    @State private var passwordSecret = ""
    @State private var totpSecret = ""
    @State private var secretMessage = ""
    @State private var deleteCandidate: TunnelProfile?

    private var index: Int? {
        appState.configuration.profiles.firstIndex { $0.id == profileID }
    }

    private var currentProfileIndex: Int? {
        appState.configuration.profiles.firstIndex { $0.id == profileID }
    }

    var body: some View {
        if let index {
            let profile = appState.configuration.profiles[index]
            let status = appState.status(for: profile)
            Form {
                Section("SSH") {
                    TextField("Name", text: binding(index, \.name))
                    TextField("Host", text: binding(index, \.host))
                    TextField(
                        "Interactive host",
                        text: optionalBinding(index, \.interactiveHost),
                        prompt: Text("Use Host")
                    )
                    TextField("User", text: optionalBinding(index, \.user))
                    TextField("SSH port", value: binding(index, \.sshPort), format: .number)
                    TextField("Local SOCKS port", value: binding(index, \.localSocksPort), format: .number)
                    TextField("Jump host", text: optionalBinding(index, \.jumpHost))
                    Picker("Host key policy", selection: binding(index, \.hostKeyPolicy)) {
                        ForEach(SSHHostKeyPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Picker("Authentication", selection: binding(index, \.authMode)) {
                        ForEach(TunnelAuthMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    TextField("Tags", text: tagsBinding(index), prompt: Text("infrastructure, production"))
                    Toggle("Automatically reconnect", isOn: binding(index, \.autoReconnect))
                    Toggle("Connect on launch", isOn: binding(index, \.connectOnLaunch))
                    Picker("Notifications", selection: binding(index, \.notificationPolicy)) {
                        ForEach(ProfileNotificationPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Picker("SSH log level", selection: binding(index, \.sshLogLevel)) {
                        ForEach(SSHLogLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    Toggle("Request remote session for tunnel", isOn: binding(index, \.tunnelRequestsRemoteSession))
                    Text("When disabled, tunnel SSH launches use -N.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Local Port Forwarding") {
                    if appState.configuration.profiles[index].localPortForwardings.isEmpty {
                        Text("No local port forwards configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.configuration.profiles[index].localPortForwardings.indices, id: \.self) { forwardingIndex in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $appState.configuration.profiles[index].localPortForwardings[forwardingIndex].enabled)
                                    .labelsHidden()
                                    .frame(width: 24)
                                TextField(
                                    "Bind",
                                    text: optionalForwardingBinding(index, forwardingIndex, \.bindAddress),
                                    prompt: Text("127.0.0.1")
                                )
                                .frame(minWidth: 110)
                                TextField(
                                    "Local port",
                                    value: $appState.configuration.profiles[index].localPortForwardings[forwardingIndex].localPort,
                                    format: .number
                                )
                                .frame(width: 90)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                TextField("Target host", text: $appState.configuration.profiles[index].localPortForwardings[forwardingIndex].targetHost)
                                    .frame(minWidth: 140)
                                TextField(
                                    "Target port",
                                    value: $appState.configuration.profiles[index].localPortForwardings[forwardingIndex].targetPort,
                                    format: .number
                                )
                                .frame(width: 90)
                                Button(role: .destructive) {
                                    removeLocalForwarding(profileIndex: index, forwardingIndex: forwardingIndex)
                                } label: {
                                    Label("Remove Forwarding", systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Remove this local port forwarding row")
                            }
                        }
                    }
                    Button {
                        addLocalForwarding(profileIndex: index)
                    } label: {
                        Label("Add Local Forward", systemImage: "plus")
                    }
                }

                Section("SSH Options") {
                    TextField("Bind address", text: curatedOptionalBinding(index, \.bindAddress))
                    Picker("Address family", selection: curatedBinding(index, \.addressFamily)) {
                        ForEach(SSHAddressFamily.allCases) { family in
                            Text(family.displayName).tag(family)
                        }
                    }
                    Picker("Compression", selection: curatedBinding(index, \.compression)) {
                        ForEach(SSHOptionToggle.allCases) { toggle in
                            Text(toggle.displayName).tag(toggle)
                        }
                    }
                    Picker("Forward agent", selection: curatedBinding(index, \.forwardAgent)) {
                        ForEach(SSHOptionToggle.allCases) { toggle in
                            Text(toggle.displayName).tag(toggle)
                        }
                    }
                    TextField("Identity files", text: stringListBinding(index, \.identityFiles), prompt: Text("~/.ssh/id_ed25519, ~/.ssh/id_rsa"))
                    TextField("Certificate files", text: stringListBinding(index, \.certificateFiles))
                    TextField("ProxyCommand", text: curatedOptionalBinding(index, \.proxyCommand))
                    TextField("Reconnect attempt limit", text: optionalIntTextBinding(index, \.maxReconnectAttempts), prompt: Text("Unlimited"))
                    TextField("Extra SSH options", text: stringListBinding(index, \.extraSSHOptions))
                }

                Section("Keychain") {
                    TextField("Account", text: keychainBinding(index, \.account))
                    TextField("Password service", text: optionalKeychainBinding(index, \.passwordService))
                    SecureField("Store password", text: $passwordSecret)
                    Button("Save Password to Keychain") {
                        saveSecret(passwordSecret, service: appState.configuration.profiles[index].keychain.passwordService)
                    }
                    TextField("TOTP service", text: optionalKeychainBinding(index, \.totpService))
                    SecureField("Store TOTP seed", text: $totpSecret)
                    HStack {
                        Button("Save TOTP Seed") {
                            saveSecret(totpSecret, service: appState.configuration.profiles[index].keychain.totpService)
                        }
                        Button("Import Existing Services") {
                            appState.importExistingKeychainServices(for: profileID)
                        }
                    }
                    if !secretMessage.isEmpty {
                        Text(secretMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showsProfileRuleSections {
                    ProfileScopedRulesEditor(profile: profile)
                }

                if showsRecentLog {
                    ProfileRecentLogSection(profile: profile)
                }

                Section("Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Connect") { appState.connect(profile) }
                            Button("Disconnect") { appState.disconnect(profile) }
                            Button("Reconnect") { appState.reconnect(profile) }
                            if appState.hasJumpHost(profile) {
                                let hopStatus = appState.hopStatus(for: profile)
                                Button(isRunning(hopStatus?.health) ? "Disconnect Hop" : "Connect Hop") {
                                    if isRunning(hopStatus?.health) {
                                        appState.disconnectHop(profile)
                                    } else {
                                        appState.connectHop(profile)
                                    }
                                }
                            }
                            Button {
                                appState.connectInteractiveSSH(profile)
                            } label: {
                                Label("Interactive SSH", systemImage: "terminal")
                            }
                            .help("Open an interactive SSH session")
                            Button {
                                appState.selectDiagnosticsProfile(profile.id)
                                openWindow(id: "diagnostics")
                                AppActivation.activate()
                            } label: {
                                Label("Diagnostics", systemImage: "stethoscope")
                            }
                            .help("Open diagnostics for this profile")
                        }
                        Button(role: .destructive) {
                            deleteCandidate = profile
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                        }
                        .help("Delete the selected profile")
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.health.rawValue.capitalized)
                                Text(status.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let pid = status.pid {
                                    Text("PID \(pid)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: symbol(for: status.health))
                                .foregroundStyle(color(for: status.health))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog(
                deleteConfirmationTitle,
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { isPresented in
                        if !isPresented {
                            deleteCandidate = nil
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
            .onChange(of: appState.configuration) {
                appState.scheduleConfigurationSave()
            }
        } else {
            PlaceholderView(title: "Profile Not Found", systemImage: "questionmark.folder")
        }
    }

    private var deleteConfirmationTitle: String {
        guard let deleteCandidate else {
            return "Delete Profile?"
        }
        return "Delete \(deleteCandidate.name)?"
    }

    private func confirmDelete(deleteKeychainItems: Bool) {
        guard let candidate = deleteCandidate else { return }
        let originalIndex = appState.configuration.profiles.firstIndex { $0.id == candidate.id }
        deleteCandidate = nil
        onDelete(candidate.id, originalIndex)
        appState.deleteProfile(id: candidate.id, deleteKeychainItems: deleteKeychainItems)
    }

    private func binding<T>(_ index: Int, _ keyPath: WritableKeyPath<TunnelProfile, T>) -> Binding<T> {
        let fallback = appState.configuration.profiles[index][keyPath: keyPath]
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index][keyPath: keyPath]
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index][keyPath: keyPath] = value
        }
    }

    private func optionalBinding(_ index: Int, _ keyPath: WritableKeyPath<TunnelProfile, String?>) -> Binding<String> {
        let fallback = appState.configuration.profiles[index][keyPath: keyPath] ?? ""
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index][keyPath: keyPath] ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index][keyPath: keyPath] = value.isEmpty ? nil : value
        }
    }

    private func tagsBinding(_ index: Int) -> Binding<String> {
        let fallback = appState.configuration.profiles[index].tags.joined(separator: ", ")
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].tags.joined(separator: ", ")
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].tags = splitList(value)
        }
    }

    private func curatedBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<CuratedSSHOptions, T>) -> Binding<T> {
        let fallback = appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath]
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath]
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = value
        }
    }

    private func curatedOptionalBinding(_ index: Int, _ keyPath: WritableKeyPath<CuratedSSHOptions, String?>) -> Binding<String> {
        let fallback = appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] ?? ""
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = value.trimmedForSettings
        }
    }

    private func stringListBinding(_ index: Int, _ keyPath: WritableKeyPath<TunnelProfile, [String]>) -> Binding<String> {
        let fallback = appState.configuration.profiles[index][keyPath: keyPath].joined(separator: ", ")
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index][keyPath: keyPath].joined(separator: ", ")
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index][keyPath: keyPath] = splitList(value)
        }
    }

    private func stringListBinding(_ index: Int, _ keyPath: WritableKeyPath<CuratedSSHOptions, [String]>) -> Binding<String> {
        let fallback = appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath].joined(separator: ", ")
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath].joined(separator: ", ")
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = splitList(value)
        }
    }

    private func optionalIntTextBinding(_ index: Int, _ keyPath: WritableKeyPath<CuratedSSHOptions, Int?>) -> Binding<String> {
        let fallback = appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath].map(String.init) ?? ""
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath].map(String.init) ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func optionalForwardingBinding(
        _ profileIndex: Int,
        _ forwardingIndex: Int,
        _ keyPath: WritableKeyPath<LocalPortForward, String?>
    ) -> Binding<String> {
        let fallback = appState.configuration.profiles[profileIndex].localPortForwardings[forwardingIndex][keyPath: keyPath] ?? ""
        return Binding {
            guard let profileIndex = currentProfileIndex,
                  appState.configuration.profiles[profileIndex].localPortForwardings.indices.contains(forwardingIndex) else {
                return fallback
            }
            return appState.configuration.profiles[profileIndex].localPortForwardings[forwardingIndex][keyPath: keyPath] ?? ""
        } set: { value in
            guard let profileIndex = currentProfileIndex,
                  appState.configuration.profiles[profileIndex].localPortForwardings.indices.contains(forwardingIndex) else {
                return
            }
            appState.configuration.profiles[profileIndex].localPortForwardings[forwardingIndex][keyPath: keyPath] = value.trimmedForSettings
        }
    }

    private func addLocalForwarding(profileIndex _: Int) {
        guard let profileIndex = currentProfileIndex else { return }
        let profile = appState.configuration.profiles[profileIndex]
        let nextPort = max(1024, profile.localSocksPort + 10_000 + profile.localPortForwardings.count)
        appState.configuration.profiles[profileIndex].localPortForwardings.append(
            LocalPortForward(localPort: nextPort, targetHost: profile.host, targetPort: profile.sshPort)
        )
    }

    private func removeLocalForwarding(profileIndex _: Int, forwardingIndex: Int) {
        guard let profileIndex = currentProfileIndex,
              appState.configuration.profiles.indices.contains(profileIndex),
              appState.configuration.profiles[profileIndex].localPortForwardings.indices.contains(forwardingIndex) else {
            return
        }
        appState.configuration.profiles[profileIndex].localPortForwardings.remove(at: forwardingIndex)
    }

    private func splitList(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func keychainBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<KeychainReference, T>) -> Binding<T> {
        let fallback = appState.configuration.profiles[index].keychain[keyPath: keyPath]
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].keychain[keyPath: keyPath]
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].keychain[keyPath: keyPath] = value
        }
    }

    private func optionalKeychainBinding(_ index: Int, _ keyPath: WritableKeyPath<KeychainReference, String?>) -> Binding<String> {
        let fallback = appState.configuration.profiles[index].keychain[keyPath: keyPath] ?? ""
        return Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].keychain[keyPath: keyPath] ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].keychain[keyPath: keyPath] = value.isEmpty ? nil : value
        }
    }

    private func saveSecret(_ value: String, service: String?) {
        guard let service, !service.isEmpty else {
            secretMessage = "Configure a service name first"
            return
        }
        guard let profile = appState.configuration.profiles.first(where: { $0.id == profileID }) else { return }
        do {
            try appState.writeSecret(value, service: service, account: profile.keychain.account)
            secretMessage = "Saved to Keychain service \(service)"
        } catch {
            secretMessage = error.localizedDescription
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

    private func isRunning(_ health: TunnelHealth?) -> Bool {
        switch health {
        case .healthy, .connecting, .degraded, .reconnecting:
            true
        case .stopped, .unhealthy, .failed, nil:
            false
        }
    }

    private func color(for health: TunnelHealth) -> Color {
        switch health {
        case .healthy: .green
        case .degraded, .connecting, .reconnecting: .orange
        case .unhealthy, .failed: .red
        case .stopped: .secondary
        }
    }
}

private struct ProfileScopedRulesEditor: View {
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
                    if let index = appState.configuration.pacRules.firstIndex(where: { $0.id == ruleID }) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Toggle("", isOn: $appState.configuration.pacRules[index].enabled)
                                .labelsHidden()
                                .frame(width: 22)
                            TextField("Name", text: $appState.configuration.pacRules[index].name)
                                .frame(minWidth: 120)
                            TextField("Domain pattern", text: $appState.configuration.pacRules[index].domainPattern)
                                .frame(minWidth: 170)
                            Picker("Failure", selection: $appState.configuration.pacRules[index].failureMode) {
                                ForEach(PACFailureMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .frame(width: 140)
                            Button(role: .destructive) {
                                deletePACRule(id: ruleID)
                            } label: {
                                Label("Delete PAC Rule", systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Delete this PAC rule")
                        }
                    }
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
                    if let index = appState.configuration.networkRules.firstIndex(where: { $0.id == ruleID }) {
                        DisclosureGroup(appState.configuration.networkRules[index].name) {
                            Toggle("Enabled", isOn: $appState.configuration.networkRules[index].enabled)
                            TextField("Name", text: $appState.configuration.networkRules[index].name)
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
                                deleteNetworkRule(id: ruleID)
                            } label: {
                                Label("Delete Network Rule", systemImage: "trash")
                            }
                        }
                    }
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

    private func optionalRuleBinding(_ value: Binding<String?>) -> Binding<String> {
        Binding {
            value.wrappedValue ?? ""
        } set: { newValue in
            value.wrappedValue = newValue.isEmpty ? nil : newValue
        }
    }
}

private struct ProfileRecentLogSection: View {
    @EnvironmentObject private var appState: AppState
    let profile: TunnelProfile

    private var profileLog: String {
        String(appState.fullSSHLog(for: profile.id).suffix(6_000))
    }

    var body: some View {
        Section("Recent Log") {
            if profileLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No SSH log captured for this profile yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Text(profileLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

private struct PlaceholderView: View {
    var title: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension String {
    var trimmedForSettings: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PACRulesView: View {
    @EnvironmentObject private var appState: AppState

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
                    if let profile = appState.configuration.profiles.first {
                        appState.configuration.pacRules.append(PACRule(name: "New rule", domainPattern: "*.example.org", profileID: profile.id))
                        appState.saveConfiguration()
                    }
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .disabled(appState.configuration.profiles.isEmpty)
                .help("Add a PAC routing rule")
            }

            List {
                ForEach(appState.configuration.pacRules) { rule in
                    pacRuleRow(ruleID: rule.id)
                }
                .onMove(perform: moveRules)
                .onDelete { offsets in
                    appState.configuration.pacRules.remove(atOffsets: offsets)
                    appState.saveConfiguration()
                }
            }
            .onChange(of: appState.configuration.pacRules) {
                appState.scheduleConfigurationSave()
            }
        }
    }

    @ViewBuilder
    private func pacRuleRow(ruleID: UUID) -> some View {
        if let index = appState.configuration.pacRules.firstIndex(where: { $0.id == ruleID }) {
            let warning = shadowWarningsByRuleID[ruleID]

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle("", isOn: $appState.configuration.pacRules[index].enabled)
                    .labelsHidden()
                    .frame(width: 22)

                if let warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("This rule is shadowed by \(warning.shadowingRuleName), which appears earlier and matches first.")
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }

                HStack(spacing: 8) {
                    iconButton(
                        systemImage: "chevron.up",
                        help: "Move rule up",
                        disabled: index == appState.configuration.pacRules.startIndex
                    ) {
                        moveRule(id: ruleID, by: -1)
                    }

                    iconButton(
                        systemImage: "chevron.down",
                        help: "Move rule down",
                        disabled: index == appState.configuration.pacRules.index(before: appState.configuration.pacRules.endIndex)
                    ) {
                        moveRule(id: ruleID, by: 1)
                    }

                    iconButton(
                        systemImage: "trash",
                        help: "Delete rule"
                    ) {
                        deleteRule(id: ruleID)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .fixedSize()

                TextField("Name", text: $appState.configuration.pacRules[index].name)
                    .frame(minWidth: 120)
                TextField("Domain pattern", text: $appState.configuration.pacRules[index].domainPattern)
                    .frame(minWidth: 150)
                Picker("Profile", selection: $appState.configuration.pacRules[index].profileID) {
                    ForEach(appState.configuration.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .frame(minWidth: 140)
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
    }

    private func moveRules(from offsets: IndexSet, to destination: Int) {
        appState.configuration.pacRules.move(fromOffsets: offsets, toOffset: destination)
        appState.saveConfiguration()
    }

    private func moveRule(id ruleID: UUID, by distance: Int) {
        guard let index = appState.configuration.pacRules.firstIndex(where: { $0.id == ruleID }) else { return }
        let newIndex = index + distance
        guard appState.configuration.pacRules.indices.contains(index),
              appState.configuration.pacRules.indices.contains(newIndex) else {
            return
        }

        let rule = appState.configuration.pacRules.remove(at: index)
        appState.configuration.pacRules.insert(rule, at: newIndex)
        appState.saveConfiguration()
    }

    private func deleteRule(id ruleID: UUID) {
        guard let index = appState.configuration.pacRules.firstIndex(where: { $0.id == ruleID }) else { return }
        guard appState.configuration.pacRules.indices.contains(index) else { return }
        appState.configuration.pacRules.remove(at: index)
        appState.saveConfiguration()
    }
}

struct NetworkRulesView: View {
    @EnvironmentObject private var appState: AppState

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
                ForEach($appState.configuration.networkRules) { $rule in
                    DisclosureGroup(rule.name) {
                        Toggle("Enabled", isOn: $rule.enabled)
                        TextField("Name", text: $rule.name)
                        Picker("Scope", selection: $rule.profileID) {
                            Text("All profiles").tag(Optional<UUID>.none)
                            ForEach(appState.configuration.profiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        TextField("Wi-Fi SSID", text: optionalRuleBinding($rule.match.wifiSSID))
                        TextField("Wi-Fi BSSID", text: optionalRuleBinding($rule.match.wifiBSSID))
                        TextField("Service contains", text: optionalRuleBinding($rule.match.serviceNameContains))
                        TextField("Search domain contains", text: optionalRuleBinding($rule.match.searchDomainContains))
                        TextField("Gateway", text: optionalRuleBinding($rule.match.gateway))
                        Picker("Action", selection: $rule.action) {
                            ForEach(NetworkPolicyAction.allCases) { action in
                                Text(action.rawValue).tag(action)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    appState.configuration.networkRules.remove(atOffsets: offsets)
                    appState.saveConfiguration()
                }
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

    private func optionalRuleBinding(_ value: Binding<String?>) -> Binding<String> {
        Binding {
            value.wrappedValue ?? ""
        } set: { newValue in
            value.wrappedValue = newValue.isEmpty ? nil : newValue
        }
    }

    private func disabledProfileNames() -> String {
        let names = appState.configuration.profiles
            .filter { appState.networkDecision.disabledProfileIDs.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? "unknown" : names.joined(separator: ", ")
    }
}

private struct NetworkFingerprintView: View {
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

struct AppPreferencesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var configurationFileMessage = ""
    @State private var sshConfigMessage = ""
    @State private var confirmsManagedSSHConfigInstall = false

    var body: some View {
        Form {
            Section("PAC") {
                SystemPACStatusDetailView()
                Text(appState.pacURL)
                    .textSelection(.enabled)
                TextField("PAC HTTP port", value: $appState.configuration.pacHTTPPort, format: .number)
                TextField("Blocking proxy port", value: $appState.configuration.blockingHTTPProxyPort, format: .number)
                Toggle("Append existing PAC", isOn: $appState.configuration.pacAppendSource.enabled)
                Picker("Existing PAC source", selection: $appState.configuration.pacAppendSource.kind) {
                    ForEach(PACAppendSourceKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(!appState.configuration.pacAppendSource.enabled)
                if appState.configuration.pacAppendSource.kind == .url {
                    TextField("Existing PAC URL", text: $appState.configuration.pacAppendSource.location)
                        .disabled(!appState.configuration.pacAppendSource.enabled)
                } else {
                    HStack {
                        TextField("Existing PAC file", text: $appState.configuration.pacAppendSource.location)
                        Button("Choose...") {
                            choosePACFile()
                        }
                        .help("Choose a PAC file path")
                    }
                    .disabled(!appState.configuration.pacAppendSource.enabled)
                }
                HStack {
                    Button("Reload Existing PAC") {
                        appState.refreshPACAppendSource(force: true)
                    }
                    .disabled(!appState.configuration.pacAppendSource.isReadyToLoad)
                    .help("Reload the configured PAC source")
                    Text(appState.pacAppendSourceMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let message = appState.configurationValidationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("System proxy", selection: $appState.configuration.proxyApplyMode) {
                    Text("Manual").tag(ProxyApplyMode.manual)
                    Text("Apply to active service").tag(ProxyApplyMode.activeNetworkServicePAC)
                }
                Button("Apply System PAC Now") {
                    appState.applySystemPAC()
                }
                .help("Apply PAC to active network service")
                Button("Restore Previous System Proxy") {
                    appState.restoreSystemPAC()
                }
                .help("Restore previous system proxy settings")
            }

            Section("Local API") {
                Text("http://127.0.0.1:\(appState.configuration.apiHTTPPort)")
                    .textSelection(.enabled)
                TextField("API HTTP port", value: $appState.configuration.apiHTTPPort, format: .number)
                SecureField("API token", text: $appState.configuration.apiToken)
                Button("Rotate API Token") {
                    appState.rotateAPIToken()
                }
                .help("Create a new local API token")
            }

            Section("Interactive SSH") {
                InteractiveTerminalPreferenceControl(style: .settings)
            }

            Section("OpenSSH Config") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            copyManagedSSHConfigSnippet()
                        } label: {
                            Label("Copy Managed Snippet", systemImage: "doc.on.doc")
                        }
                        .help("Copy managed SSH config snippet")
                        Button {
                            confirmsManagedSSHConfigInstall = true
                        } label: {
                            Label("Install Managed Include...", systemImage: "square.and.arrow.down")
                        }
                        .help("Install managed SSH include configuration")
                    }
                    ScrollView {
                        Text(managedSSHConfigPreview())
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                    if !sshConfigMessage.isEmpty {
                        Text(sshConfigMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Migration") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Export Configuration...") {
                            exportConfiguration()
                        }
                        Button("Validate Configuration...") {
                            validateConfiguration()
                        }
                    }
                    HStack {
                        Button("Import Configuration...") {
                            importConfiguration()
                        }
                        Button("Create Support Bundle...") {
                            createSupportBundle()
                        }
                    }
                    if !configurationFileMessage.isEmpty {
                        Text(configurationFileMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Check ssh-auto2fa Services") {
                        appState.refreshSSHAuto2FAServiceStatuses()
                    }
                    Button("Import ssh-auto2fa Presets") {
                        appState.importSSHAuto2FAPresets()
                    }
                    Button("Import SSH Config") {
                        do {
                            try appState.importSSHConfig()
                        } catch {
                            appState.lastProxyMessage = "Could not import SSH config: \(error.localizedDescription)"
                        }
                    }
                }
                if !appState.sshAuto2FAServiceStatuses.isEmpty {
                    ForEach(appState.sshAuto2FAServiceStatuses) { status in
                        HStack {
                            Text(status.requirement.profileName)
                            Text(status.requirement.kind.displayName)
                                .foregroundStyle(.secondary)
                            Text(status.requirement.service)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(status.requirement.account)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Text(keychainStatusLabel(status.state))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                Text("Imports legacy ssh-auto2fa CERN and PSI Tier-3 service names, or imports literal hosts from ~/.ssh/config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.configuration) {
            appState.scheduleConfigurationSave()
        }
        .confirmationDialog(
            "Install SSH AutoTunnel managed OpenSSH config?",
            isPresented: $confirmsManagedSSHConfigInstall,
            titleVisibility: .visible
        ) {
            Button("Install Managed Include") {
                installManagedSSHConfig()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes ~/.ssh/config.d/ssh-autotunnel.conf and adds a marked Include block to ~/.ssh/config. Existing SSH config blocks are not edited.")
        }
    }

    private func keychainStatusLabel(_ state: KeychainCredentialState) -> String {
        switch state {
        case .available: "Found"
        case .missing: "Missing"
        case .unreadable: "Unreadable"
        }
    }

    private func copyManagedSSHConfigSnippet() {
        do {
            let snippet = try appState.managedSSHConfigSnippet()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet, forType: .string)
            sshConfigMessage = "Copied managed OpenSSH config snippet"
        } catch {
            sshConfigMessage = "Could not copy managed OpenSSH config: \(error.localizedDescription)"
        }
    }

    private func installManagedSSHConfig() {
        do {
            let result = try appState.installManagedSSHConfig()
            let includeStatus = result.updatedMainConfig ? "added include" : "include already present"
            let backupStatus = result.backupURL.map { " Backup: \($0.path)" } ?? ""
            sshConfigMessage = "Installed \(result.managedConfigURL.path), \(includeStatus).\(backupStatus)"
        } catch {
            sshConfigMessage = "Could not install managed OpenSSH config: \(error.localizedDescription)"
        }
    }

    private func managedSSHConfigPreview() -> String {
        do {
            return try appState.managedSSHConfigSnippet()
        } catch {
            return "Could not render managed OpenSSH config: \(error.localizedDescription)"
        }
    }

    private func exportConfiguration() {
        guard let url = saveURL(defaultFileName: "ssh-autotunnel-config.json") else { return }
        do {
            try writeJSON(appState.configurationExport(), to: url)
            configurationFileMessage = "Exported configuration to \(url.path)"
        } catch {
            configurationFileMessage = "Could not export configuration: \(error.localizedDescription)"
        }
    }

    private func validateConfiguration() {
        guard let url = openURL() else { return }
        do {
            let export = try readConfigurationExport(from: url)
            let report = appState.configurationValidationReport(for: export)
            configurationFileMessage = validationMessage(report)
        } catch {
            configurationFileMessage = "Could not validate configuration: \(error.localizedDescription)"
        }
    }

    private func importConfiguration() {
        guard let url = openURL() else { return }
        do {
            let export = try readConfigurationExport(from: url)
            let report = appState.configurationValidationReport(for: export)
            guard report.ok else {
                configurationFileMessage = validationMessage(report)
                return
            }
            guard confirmImport(report) else {
                configurationFileMessage = "Import canceled"
                return
            }
            let response = appState.importConfigurationExport(export)
            configurationFileMessage = response.message
        } catch {
            configurationFileMessage = "Could not import configuration: \(error.localizedDescription)"
        }
    }

    private func createSupportBundle() {
        guard let url = saveURL(defaultFileName: "ssh-autotunnel-support.json") else { return }
        do {
            try writeJSON(appState.supportBundle(), to: url)
            configurationFileMessage = "Created support bundle at \(url.path)"
        } catch {
            configurationFileMessage = "Could not create support bundle: \(error.localizedDescription)"
        }
    }

    private func saveURL(defaultFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultFileName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func choosePACFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.configuration.pacAppendSource.kind = .file
        appState.configuration.pacAppendSource.location = url.path
        appState.saveConfiguration()
        appState.refreshPACAppendSource(force: true)
    }

    private func openURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func readConfigurationExport(from url: URL) throws -> ConfigurationExport {
        let data = try Data(contentsOf: url)
        return try ConfigurationExportService.decodeExportDocument(from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try data.write(to: url, options: [.atomic])
        try FileProtection.protectFile(url)
    }

    private func validationMessage(_ report: ConfigurationValidationReport) -> String {
        let warningSuffix = report.warnings.isEmpty ? "" : " Warnings: \(report.warnings.joined(separator: "; "))"
        if report.ok {
            return "Configuration is valid: \(report.profileCount) profiles, \(report.pacRuleCount) PAC rules, \(report.networkRuleCount) network rules.\(warningSuffix)"
        }
        let details = report.messages.isEmpty ? report.message : report.messages.joined(separator: "; ")
        return "Configuration is invalid: \(details).\(warningSuffix)"
    }

    private func confirmImport(_ report: ConfigurationValidationReport) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import Configuration?"
        let warningText = report.warnings.isEmpty ? "" : "\n\nWarnings:\n\(report.warnings.joined(separator: "\n"))"
        alert.informativeText = "This will replace the current profiles and rules with \(report.profileCount) profiles, \(report.pacRuleCount) PAC rules, and \(report.networkRuleCount) network rules. A private pre-import backup will be created first.\(warningText)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
