import SSHAutoTunnelCore
import SwiftUI

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
                        appState.deleteProfiles(at: offsets)
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
            }
        } detail: {
            TabView {
                if let selectedProfileID, appState.configuration.profiles.contains(where: { $0.id == selectedProfileID }) {
                    ProfileEditorView(profileID: selectedProfileID)
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
    @State private var passwordSecret = ""
    @State private var totpSecret = ""
    @State private var secretMessage = ""

    private var index: Int? {
        appState.configuration.profiles.firstIndex { $0.id == profileID }
    }

    var body: some View {
        if let index {
            Form {
                Section("SSH") {
                    TextField("Name", text: binding(index, \.name))
                    TextField("Host", text: binding(index, \.host))
                    TextField("User", text: optionalBinding(index, \.user))
                    TextField("SSH port", value: binding(index, \.sshPort), format: .number)
                    TextField("Local SOCKS port", value: binding(index, \.localSocksPort), format: .number)
                    TextField("Jump host", text: optionalBinding(index, \.jumpHost))
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
                    HStack {
                        Button("Connect") { appState.connect(appState.configuration.profiles[index]) }
                        Button("Disconnect") { appState.disconnect(appState.configuration.profiles[index]) }
                        Button("Reconnect") { appState.reconnect(appState.configuration.profiles[index]) }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: appState.configuration) { _ in
                appState.saveConfiguration()
            }
        } else {
            PlaceholderView(title: "Profile Not Found", systemImage: "questionmark.folder")
        }
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
            .onChange(of: appState.configuration.pacRules) { _ in
                appState.saveConfiguration()
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
        .onChange(of: appState.configuration.networkRules) { _ in
            appState.saveConfiguration()
        }
    }

    private func optionalRuleBinding(_ value: Binding<String?>) -> Binding<String> {
        Binding {
            value.wrappedValue ?? ""
        } set: { newValue in
            value.wrappedValue = newValue.isEmpty ? nil : newValue
        }
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

    var body: some View {
        Form {
            Section("PAC") {
                Text(appState.pacURL)
                    .textSelection(.enabled)
                TextField("PAC HTTP port", value: $appState.configuration.pacHTTPPort, format: .number)
                TextField("Blocking proxy port", value: $appState.configuration.blockingHTTPProxyPort, format: .number)
                Picker("System proxy", selection: $appState.configuration.proxyApplyMode) {
                    Text("Manual").tag(ProxyApplyMode.manual)
                    Text("Apply to active service").tag(ProxyApplyMode.activeNetworkServicePAC)
                }
                Button("Apply System PAC Now") {
                    appState.applySystemPAC()
                }
                Button("Restore Previous System Proxy") {
                    appState.restoreSystemPAC()
                }
            }

            Section("Local API") {
                Text("http://127.0.0.1:\(appState.configuration.apiHTTPPort)")
                    .textSelection(.enabled)
                TextField("API HTTP port", value: $appState.configuration.apiHTTPPort, format: .number)
                SecureField("API token", text: $appState.configuration.apiToken)
                Button("Rotate API Token") {
                    appState.rotateAPIToken()
                }
            }

            Section("Migration") {
                Button("Import ssh-auto2fa Presets") {
                    appState.importSSHAuto2FAPresets()
                }
                Text("Creates or updates CERN lxplus and PSI Tier-3 profiles using the existing Keychain service names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.configuration) { _ in
            appState.saveConfiguration()
        }
    }
}
