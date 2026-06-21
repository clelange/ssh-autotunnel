import SSHAutoTunnelCore
import SwiftUI

struct ProfileDetailPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let profile: TunnelProfile
    var onDelete: (UUID, Int?) -> Void
    @State private var selectedSection: ProfileDetailSection = .general
    @State private var deleteCandidate: TunnelProfile?

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

            Picker("Profile Section", selection: $selectedSection) {
                ForEach(ProfileDetailSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            ProfileEditorView(profileID: profile.id, section: selectedSection)
                .environmentObject(appState)
        }
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.name)
                    .font(.title2.weight(.semibold))
                Text(endpointSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                TagRow(tags: profile.tags)
                VStack(alignment: .leading, spacing: 4) {
                    StatusLine(label: "Tunnel", health: tunnel.health, message: tunnel.message, pid: tunnel.pid)
                    if let hop {
                        StatusLine(label: "Hop", health: hop.health, message: hop.message, pid: hop.pid)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    Button("Connect") { appState.connect(profile) }
                    Button("Disconnect") { appState.disconnect(profile) }
                    Button("Reconnect") { appState.reconnect(profile) }
                }
                HStack(spacing: 6) {
                    if appState.hasJumpHost(profile) {
                        Button(hop?.health.isRunning == true ? "Disconnect Hop" : "Connect Hop") {
                            if hop?.health.isRunning == true {
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
                    Button {
                        appState.selectDiagnosticsProfile(profile.id)
                        openWindow(id: "diagnostics")
                        AppActivation.activate()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                    Button(role: .destructive) {
                        deleteCandidate = profile
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .buttonStyle(.bordered)
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
}

enum ProfileDetailSection: String, CaseIterable, Identifiable {
    case general
    case forwarding
    case auth
    case sshOptions
    case rules
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .forwarding: "Forwarding"
        case .auth: "Auth"
        case .sshOptions: "SSH Options"
        case .rules: "Rules"
        case .logs: "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "server.rack"
        case .forwarding: "arrow.left.arrow.right"
        case .auth: "key"
        case .sshOptions: "slider.horizontal.3"
        case .rules: "list.bullet.rectangle"
        case .logs: "doc.text"
        }
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject private var appState: AppState
    let profileID: UUID
    let section: ProfileDetailSection
    @State private var passwordSecret = ""
    @State private var totpSecret = ""
    @State private var secretMessage = ""

    private var currentProfileIndex: Int? {
        appState.configuration.profiles.firstIndex { $0.id == profileID }
    }

    private var currentProfile: TunnelProfile? {
        guard let currentProfileIndex else { return nil }
        return appState.configuration.profiles[currentProfileIndex]
    }

    var body: some View {
        if let profile = currentProfile {
            Form {
                switch section {
                case .general:
                    generalSection(profile)
                case .forwarding:
                    forwardingSection(profile)
                case .auth:
                    authSection(profile)
                case .sshOptions:
                    sshOptionsSection(profile)
                case .rules:
                    ProfileScopedRulesEditor(profile: profile)
                case .logs:
                    ProfileRecentLogSection(profile: profile)
                }
            }
            .formStyle(.grouped)
            .onChange(of: appState.configuration) {
                appState.scheduleConfigurationSave()
            }
        } else {
            PlaceholderView(title: "Profile Not Found", systemImage: "questionmark.folder")
        }
    }

    @ViewBuilder
    private func generalSection(_ profile: TunnelProfile) -> some View {
        Section("Connection") {
            TextField("Name", text: binding(\.name, fallback: profile.name))
            TextField("Host", text: binding(\.host, fallback: profile.host))
            TextField("Interactive host", text: optionalBinding(\.interactiveHost, fallback: profile.interactiveHost ?? ""), prompt: Text("Use Host"))
            TextField("User", text: optionalBinding(\.user, fallback: profile.user ?? ""))
            TextField("SSH port", value: binding(\.sshPort, fallback: profile.sshPort), format: .number)
            TextField("Local SOCKS port", value: binding(\.localSocksPort, fallback: profile.localSocksPort), format: .number)
            TextField("Jump host", text: optionalBinding(\.jumpHost, fallback: profile.jumpHost ?? ""))
            TextField("Tags", text: tagsBinding(fallback: profile.tags.joined(separator: ", ")), prompt: Text("infrastructure, production"))
            Picker("Host key policy", selection: binding(\.hostKeyPolicy, fallback: profile.hostKeyPolicy)) {
                ForEach(SSHHostKeyPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
        }

        Section("Behavior") {
            Toggle("Automatically reconnect", isOn: binding(\.autoReconnect, fallback: profile.autoReconnect))
            Toggle("Connect on launch", isOn: binding(\.connectOnLaunch, fallback: profile.connectOnLaunch))
            Picker("Notifications", selection: binding(\.notificationPolicy, fallback: profile.notificationPolicy)) {
                ForEach(ProfileNotificationPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            Picker("SSH log level", selection: binding(\.sshLogLevel, fallback: profile.sshLogLevel)) {
                ForEach(SSHLogLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            Toggle("Request remote session for tunnel", isOn: binding(\.tunnelRequestsRemoteSession, fallback: profile.tunnelRequestsRemoteSession))
            Text("When disabled, tunnel SSH launches use -N.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func forwardingSection(_ profile: TunnelProfile) -> some View {
        Section("Dynamic SOCKS Forwarding") {
            Text("SOCKS proxy on 127.0.0.1:\(profile.localSocksPort)")
                .textSelection(.enabled)
        }

        Section("Local Port Forwarding") {
            if profile.localPortForwardings.isEmpty {
                Text("No local port forwards configured.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profile.localPortForwardings) { forwarding in
                    localForwardingRow(forwarding)
                }
            }
            Button {
                addLocalForwarding()
            } label: {
                Label("Add Local Forward", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private func authSection(_ profile: TunnelProfile) -> some View {
        Section("Authentication") {
            Picker("Authentication", selection: binding(\.authMode, fallback: profile.authMode)) {
                ForEach(TunnelAuthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            TextField("Account", text: keychainBinding(\.account, fallback: profile.keychain.account))
            TextField("Password service", text: optionalKeychainBinding(\.passwordService, fallback: profile.keychain.passwordService ?? ""))
            SecureField("Store password", text: $passwordSecret)
            Button("Save Password to Keychain") {
                saveSecret(passwordSecret, service: currentProfile?.keychain.passwordService)
            }
            TextField("TOTP service", text: optionalKeychainBinding(\.totpService, fallback: profile.keychain.totpService ?? ""))
            SecureField("Store TOTP seed", text: $totpSecret)
            HStack {
                Button("Save TOTP Seed") {
                    saveSecret(totpSecret, service: currentProfile?.keychain.totpService)
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
    }

    @ViewBuilder
    private func sshOptionsSection(_ profile: TunnelProfile) -> some View {
        Section("Curated SSH Options") {
            TextField("Bind address", text: curatedOptionalBinding(\.bindAddress, fallback: profile.curatedSSHOptions.bindAddress ?? ""))
            Picker("Address family", selection: curatedBinding(\.addressFamily, fallback: profile.curatedSSHOptions.addressFamily)) {
                ForEach(SSHAddressFamily.allCases) { family in
                    Text(family.displayName).tag(family)
                }
            }
            Picker("Compression", selection: curatedBinding(\.compression, fallback: profile.curatedSSHOptions.compression)) {
                ForEach(SSHOptionToggle.allCases) { toggle in
                    Text(toggle.displayName).tag(toggle)
                }
            }
            Picker("Forward agent", selection: curatedBinding(\.forwardAgent, fallback: profile.curatedSSHOptions.forwardAgent)) {
                ForEach(SSHOptionToggle.allCases) { toggle in
                    Text(toggle.displayName).tag(toggle)
                }
            }
            TextField("Identity files", text: stringListBinding(\.identityFiles, fallback: profile.curatedSSHOptions.identityFiles.joined(separator: ", ")), prompt: Text("~/.ssh/id_ed25519, ~/.ssh/id_rsa"))
            TextField("Certificate files", text: stringListBinding(\.certificateFiles, fallback: profile.curatedSSHOptions.certificateFiles.joined(separator: ", ")))
            TextField("ProxyCommand", text: curatedOptionalBinding(\.proxyCommand, fallback: profile.curatedSSHOptions.proxyCommand ?? ""))
            TextField("Reconnect attempt limit", text: optionalIntTextBinding(\.maxReconnectAttempts, fallback: profile.curatedSSHOptions.maxReconnectAttempts.map(String.init) ?? ""), prompt: Text("Unlimited"))
        }

        Section("Escape Hatch") {
            TextField("Extra SSH options", text: stringListBinding(\.extraSSHOptions, fallback: profile.extraSSHOptions.joined(separator: ", ")))
        }
    }

    private func localForwardingRow(_ forwarding: LocalPortForward) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: forwardingBinding(forwarding.id, \.enabled, fallback: forwarding.enabled))
                .labelsHidden()
                .frame(width: 24)
            TextField("Bind", text: optionalForwardingBinding(forwarding.id, \.bindAddress, fallback: forwarding.bindAddress ?? ""), prompt: Text("127.0.0.1"))
                .frame(minWidth: 110)
            TextField("Local port", value: forwardingBinding(forwarding.id, \.localPort, fallback: forwarding.localPort), format: .number)
                .frame(width: 90)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("Target host", text: forwardingBinding(forwarding.id, \.targetHost, fallback: forwarding.targetHost))
                .frame(minWidth: 140)
            TextField("Target port", value: forwardingBinding(forwarding.id, \.targetPort, fallback: forwarding.targetPort), format: .number)
                .frame(width: 90)
            Button(role: .destructive) {
                removeLocalForwarding(id: forwarding.id)
            } label: {
                Label("Remove Forwarding", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove this local port forwarding row")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<TunnelProfile, T>, fallback: T) -> Binding<T> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index][keyPath: keyPath]
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index][keyPath: keyPath] = value
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<TunnelProfile, String?>, fallback: String) -> Binding<String> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index][keyPath: keyPath] ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index][keyPath: keyPath] = value.isEmpty ? nil : value
        }
    }

    private func tagsBinding(fallback: String) -> Binding<String> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].tags.joined(separator: ", ")
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].tags = splitList(value)
        }
    }

    private func curatedBinding<T>(_ keyPath: WritableKeyPath<CuratedSSHOptions, T>, fallback: T) -> Binding<T> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath]
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = value
        }
    }

    private func curatedOptionalBinding(_ keyPath: WritableKeyPath<CuratedSSHOptions, String?>, fallback: String) -> Binding<String> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = value.trimmedForSettings
        }
    }

    private func stringListBinding(_ keyPath: WritableKeyPath<TunnelProfile, [String]>, fallback: String) -> Binding<String> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index][keyPath: keyPath].joined(separator: ", ")
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index][keyPath: keyPath] = splitList(value)
        }
    }

    private func stringListBinding(_ keyPath: WritableKeyPath<CuratedSSHOptions, [String]>, fallback: String) -> Binding<String> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath].joined(separator: ", ")
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = splitList(value)
        }
    }

    private func optionalIntTextBinding(_ keyPath: WritableKeyPath<CuratedSSHOptions, Int?>, fallback: String) -> Binding<String> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath].map(String.init) ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].curatedSSHOptions[keyPath: keyPath] = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func keychainBinding<T>(_ keyPath: WritableKeyPath<KeychainReference, T>, fallback: T) -> Binding<T> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].keychain[keyPath: keyPath]
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].keychain[keyPath: keyPath] = value
        }
    }

    private func optionalKeychainBinding(_ keyPath: WritableKeyPath<KeychainReference, String?>, fallback: String) -> Binding<String> {
        Binding {
            guard let index = currentProfileIndex else { return fallback }
            return appState.configuration.profiles[index].keychain[keyPath: keyPath] ?? ""
        } set: { value in
            guard let index = currentProfileIndex else { return }
            appState.configuration.profiles[index].keychain[keyPath: keyPath] = value.isEmpty ? nil : value
        }
    }

    private func forwardingIndex(id forwardingID: UUID) -> Int? {
        guard let profileIndex = currentProfileIndex else { return nil }
        return appState.configuration.profiles[profileIndex].localPortForwardings.firstIndex { $0.id == forwardingID }
    }

    private func forwardingBinding<T>(_ forwardingID: UUID, _ keyPath: WritableKeyPath<LocalPortForward, T>, fallback: T) -> Binding<T> {
        Binding {
            guard let profileIndex = currentProfileIndex,
                  let forwardingIndex = forwardingIndex(id: forwardingID) else {
                return fallback
            }
            return appState.configuration.profiles[profileIndex].localPortForwardings[forwardingIndex][keyPath: keyPath]
        } set: { value in
            guard let profileIndex = currentProfileIndex,
                  let forwardingIndex = forwardingIndex(id: forwardingID) else {
                return
            }
            appState.configuration.profiles[profileIndex].localPortForwardings[forwardingIndex][keyPath: keyPath] = value
        }
    }

    private func optionalForwardingBinding(_ forwardingID: UUID, _ keyPath: WritableKeyPath<LocalPortForward, String?>, fallback: String) -> Binding<String> {
        Binding {
            guard let profileIndex = currentProfileIndex,
                  let forwardingIndex = forwardingIndex(id: forwardingID) else {
                return fallback
            }
            return appState.configuration.profiles[profileIndex].localPortForwardings[forwardingIndex][keyPath: keyPath] ?? ""
        } set: { value in
            guard let profileIndex = currentProfileIndex,
                  let forwardingIndex = forwardingIndex(id: forwardingID) else {
                return
            }
            appState.configuration.profiles[profileIndex].localPortForwardings[forwardingIndex][keyPath: keyPath] = value.trimmedForSettings
        }
    }

    private func addLocalForwarding() {
        guard let profileIndex = currentProfileIndex else { return }
        let profile = appState.configuration.profiles[profileIndex]
        let nextPort = max(1024, profile.localSocksPort + 10_000 + profile.localPortForwardings.count)
        appState.configuration.profiles[profileIndex].localPortForwardings.append(
            LocalPortForward(localPort: nextPort, targetHost: profile.host, targetPort: profile.sshPort)
        )
        appState.saveConfiguration()
    }

    private func removeLocalForwarding(id forwardingID: UUID) {
        guard let profileIndex = currentProfileIndex else { return }
        appState.configuration.profiles[profileIndex].localPortForwardings.removeAll { $0.id == forwardingID }
        appState.saveConfiguration()
    }

    private func saveSecret(_ value: String, service: String?) {
        guard let service, !service.isEmpty else {
            secretMessage = "Configure a service name first"
            return
        }
        guard let profile = currentProfile else { return }
        do {
            try appState.writeSecret(value, service: service, account: profile.keychain.account)
            secretMessage = "Saved to Keychain service \(service)"
        } catch {
            secretMessage = error.localizedDescription
        }
    }

    private func splitList(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
                .frame(maxHeight: 320)
            }
        }
    }
}
