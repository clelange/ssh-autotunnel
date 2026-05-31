import AppKit
import SSHAutoTunnelCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedProfileID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProfileID) {
                Section("Profiles") {
                    ForEach(appState.configuration.profiles) { profile in
                        Label(profile.name, systemImage: "server.rack")
                            .tag(profile.id)
                    }
                    .onDelete { offsets in
                        let deletedIDs = Set(offsets.map { appState.configuration.profiles[$0].id })
                        appState.deleteProfiles(at: offsets)
                        if let selectedProfileID, deletedIDs.contains(selectedProfileID) {
                            self.selectedProfileID = appState.configuration.profiles.first?.id
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .toolbar {
                Button {
                    appState.addGenericProfile()
                    selectedProfileID = appState.configuration.profiles.last?.id
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
                .help("Create a new profile")
            }
        } detail: {
            TabView {
                if let selectedProfileID, appState.configuration.profiles.contains(where: { $0.id == selectedProfileID }) {
                    ProfileEditorView(profileID: selectedProfileID) { deletedProfileID in
                        if selectedProfileID == deletedProfileID {
                            self.selectedProfileID = appState.configuration.profiles.first?.id
                        }
                    }
                        .tabItem { Label("Profile", systemImage: "server.rack") }
                } else {
                    PlaceholderView(title: "Select a Profile", systemImage: "server.rack")
                        .tabItem { Label("Profile", systemImage: "server.rack") }
                }

                PACRulesView()
                    .tabItem { Label("PAC Rules", systemImage: "point.3.connected.trianglepath.dotted") }

                NetworkRulesView()
                    .tabItem { Label("Networks", systemImage: "wifi.router") }

                AppPreferencesView()
                    .tabItem { Label("App", systemImage: "gearshape") }
            }
            .padding()
        }
        .onAppear {
            selectedProfileID = selectedProfileID ?? appState.configuration.profiles.first?.id
        }
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject private var appState: AppState
    let profileID: UUID
    var onDelete: (UUID) -> Void = { _ in }
    @State private var passwordSecret = ""
    @State private var totpSecret = ""
    @State private var secretMessage = ""
    @State private var deleteCandidate: TunnelProfile?

    private var index: Int? {
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
                    Toggle("Automatically reconnect", isOn: binding(index, \.autoReconnect))
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

                Section("Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Connect") { appState.connect(profile) }
                            Button("Disconnect") { appState.disconnect(profile) }
                            Button("Reconnect") { appState.reconnect(profile) }
                            Button {
                                appState.connectInteractiveSSH(profile)
                            } label: {
                                Label("Interactive SSH", systemImage: "terminal")
                            }
                            .help("Open an interactive SSH session")
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
        deleteCandidate = nil
        appState.deleteProfile(id: candidate.id, deleteKeychainItems: deleteKeychainItems)
        onDelete(candidate.id)
    }

    private func binding<T>(_ index: Int, _ keyPath: WritableKeyPath<TunnelProfile, T>) -> Binding<T> {
        Binding {
            appState.configuration.profiles[index][keyPath: keyPath]
        } set: { value in
            appState.configuration.profiles[index][keyPath: keyPath] = value
        }
    }

    private func optionalBinding(_ index: Int, _ keyPath: WritableKeyPath<TunnelProfile, String?>) -> Binding<String> {
        Binding {
            appState.configuration.profiles[index][keyPath: keyPath] ?? ""
        } set: { value in
            appState.configuration.profiles[index][keyPath: keyPath] = value.isEmpty ? nil : value
        }
    }

    private func keychainBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<KeychainReference, T>) -> Binding<T> {
        Binding {
            appState.configuration.profiles[index].keychain[keyPath: keyPath]
        } set: { value in
            appState.configuration.profiles[index].keychain[keyPath: keyPath] = value
        }
    }

    private func optionalKeychainBinding(_ index: Int, _ keyPath: WritableKeyPath<KeychainReference, String?>) -> Binding<String> {
        Binding {
            appState.configuration.profiles[index].keychain[keyPath: keyPath] ?? ""
        } set: { value in
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

    private func color(for health: TunnelHealth) -> Color {
        switch health {
        case .healthy: .green
        case .degraded, .connecting, .reconnecting: .orange
        case .unhealthy, .failed: .red
        case .stopped: .secondary
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

struct PACRulesView: View {
    @EnvironmentObject private var appState: AppState

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
                .help("Add a PAC routing rule")
            }

            List {
                ForEach($appState.configuration.pacRules) { $rule in
                    Grid(alignment: .leadingFirstTextBaseline) {
                        GridRow {
                            Toggle("", isOn: $rule.enabled)
                                .labelsHidden()
                            TextField("Name", text: $rule.name)
                            TextField("Domain pattern", text: $rule.domainPattern)
                            Picker("Profile", selection: $rule.profileID) {
                                ForEach(appState.configuration.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            Picker("Failure", selection: $rule.failureMode) {
                                ForEach(PACFailureMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                        }
                    }
                }
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
                    appState.configuration.networkRules.append(NetworkPolicyRule(name: "Trusted network", match: NetworkMatch(), action: .disableProxy))
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
                Picker("Terminal app", selection: $appState.configuration.interactiveTerminal.app) {
                    ForEach(InteractiveTerminalApp.allCases) { app in
                        Text(app.displayName).tag(app)
                    }
                }

                if appState.configuration.interactiveTerminal.app == .custom {
                    HStack {
                        TextField("Application", text: $appState.configuration.interactiveTerminal.customApplicationPath)
                        Button("Choose...") {
                            chooseTerminalApplication()
                        }
                        .help("Choose a custom terminal app for interactive SSH")
                    }
                    Text("Custom terminal apps must accept command launches with `-e /bin/zsh -lc ...`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(appState.interactiveTerminalAvailabilityMessage())
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        Text(appState.managedSSHConfigSnippet())
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appState.managedSSHConfigSnippet(), forType: .string)
        sshConfigMessage = "Copied managed OpenSSH config snippet"
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

    private func chooseTerminalApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.configuration.interactiveTerminal.app = .custom
        appState.configuration.interactiveTerminal.customApplicationPath = url.path
        appState.saveConfiguration()
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
        if report.ok {
            return "Configuration is valid: \(report.profileCount) profiles, \(report.pacRuleCount) PAC rules, \(report.networkRuleCount) network rules"
        }
        let details = report.messages.isEmpty ? report.message : report.messages.joined(separator: "; ")
        return "Configuration is invalid: \(details)"
    }

    private func confirmImport(_ report: ConfigurationValidationReport) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import Configuration?"
        alert.informativeText = "This will replace the current profiles and rules with \(report.profileCount) profiles, \(report.pacRuleCount) PAC rules, and \(report.networkRuleCount) network rules. A private pre-import backup will be created first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
