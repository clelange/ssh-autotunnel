import AppIntents
import Foundation
import SSHAutoTunnelCore

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect SSH Tunnel"
    static var description = IntentDescription("Connect an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "CERN lxplus"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .connect, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect SSH Tunnel"
    static var description = IntentDescription("Disconnect an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "CERN lxplus"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .disconnect, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ReconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Reconnect SSH Tunnel"
    static var description = IntentDescription("Reconnect an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "CERN lxplus"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .reconnect, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct TunnelStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel Status"
    static var description = IntentDescription("Get the current SSH AutoTunnel status.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .status))
        let summary = response.status?.profiles.map { "\($0.name): \($0.health.rawValue)" }.joined(separator: ", ") ?? response.message
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct PACURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel PAC URL"
    static var description = IntentDescription("Get the local PAC URL for SSH AutoTunnel.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .pacURL))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ReloadPACIntent: AppIntent {
    static var title: LocalizedStringResource = "Reload SSH AutoTunnel PAC"
    static var description = IntentDescription("Regenerate the local SSH AutoTunnel PAC file.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .reloadPAC))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ApplySystemPACIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply SSH AutoTunnel System PAC"
    static var description = IntentDescription("Apply the SSH AutoTunnel PAC URL to the active macOS network service.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .applySystemPAC))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct RestoreSystemProxyIntent: AppIntent {
    static var title: LocalizedStringResource = "Restore SSH AutoTunnel System Proxy"
    static var description = IntentDescription("Restore the macOS proxy settings saved before SSH AutoTunnel applied system PAC.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .restoreSystemPAC))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ImportSSHAuto2FAIntent: AppIntent {
    static var title: LocalizedStringResource = "Import ssh-auto2fa Presets"
    static var description = IntentDescription("Create or update SSH AutoTunnel profiles from known ssh-auto2fa Keychain service names.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .importSSHAuto2FA))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct CheckSSHAuto2FAIntent: AppIntent {
    static var title: LocalizedStringResource = "Check ssh-auto2fa Keychain"
    static var description = IntentDescription("Check whether known ssh-auto2fa Keychain services are available.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .checkSSHAuto2FA))
        let statuses = response.sshAuto2FAServiceStatuses ?? []
        let summary = statuses.isEmpty
            ? response.message
            : statuses.map { status in
                "\(status.requirement.profileName) \(status.requirement.kind.displayName): \(label(for: status.state))"
            }.joined(separator: ", ")
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct ImportSSHConfigIntent: AppIntent {
    static var title: LocalizedStringResource = "Import SSH Config"
    static var description = IntentDescription("Create or update SSH AutoTunnel profiles from literal Host entries in ~/.ssh/config.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .importSSHConfig))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct CreateProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Create SSH AutoTunnel Profile"
    static var description = IntentDescription("Create an SSH AutoTunnel profile from Shortcuts or Automations.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Host")
    var host: String

    @Parameter(title: "Local SOCKS Port")
    var localSocksPort: Int

    @Parameter(title: "SSH Port")
    var sshPort: Int

    @Parameter(title: "User")
    var user: String

    @Parameter(title: "Jump Host")
    var jumpHost: String

    init() {
        name = "New tunnel"
        host = "example.org"
        localSocksPort = 1083
        sshPort = 22
        user = ""
        jumpHost = ""
    }

    init(name: String, host: String, localSocksPort: Int, sshPort: Int = 22, user: String = "", jumpHost: String = "") {
        self.name = name
        self.host = host
        self.localSocksPort = localSocksPort
        self.sshPort = sshPort
        self.user = user
        self.jumpHost = jumpHost
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = TunnelProfile(
            name: name,
            host: host,
            user: optionalString(user),
            sshPort: sshPort,
            localSocksPort: localSocksPort,
            jumpHost: optionalString(jumpHost)
        )
        let response = try await api().send(ControlRequest(action: .createProfile, profile: profile))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct UpdateProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Update SSH AutoTunnel Profile"
    static var description = IntentDescription("Update basic SSH AutoTunnel profile fields from Shortcuts or Automations.")

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Host")
    var host: String

    @Parameter(title: "Local SOCKS Port")
    var localSocksPort: Int

    @Parameter(title: "SSH Port")
    var sshPort: Int

    @Parameter(title: "User")
    var user: String

    @Parameter(title: "Jump Host")
    var jumpHost: String

    init() {
        profileName = "CERN lxplus"
        host = "lxplus.cern.ch"
        localSocksPort = 1081
        sshPort = 22
        user = ""
        jumpHost = ""
    }

    init(profileName: String, host: String, localSocksPort: Int, sshPort: Int = 22, user: String = "", jumpHost: String = "") {
        self.profileName = profileName
        self.host = host
        self.localSocksPort = localSocksPort
        self.sshPort = sshPort
        self.user = user
        self.jumpHost = jumpHost
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = TunnelProfile(
            name: profileName,
            host: host,
            user: optionalString(user),
            sshPort: sshPort,
            localSocksPort: localSocksPort,
            jumpHost: optionalString(jumpHost)
        )
        let response = try await api().send(ControlRequest(action: .updateProfile, profileName: profileName, profile: profile))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DeleteProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete SSH AutoTunnel Profile"
    static var description = IntentDescription("Delete an SSH AutoTunnel profile by name.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "Old tunnel"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .deleteProfile, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DiagnosticsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel Diagnostics"
    static var description = IntentDescription("Get a structured SSH AutoTunnel diagnostics summary.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .diagnostics))
        let diagnostics = response.diagnostics
        let activePorts = diagnostics?.activePorts.map {
            "PAC \($0.pacHTTPPort), API \($0.apiHTTPPort), blocking proxy \($0.blockingHTTPProxyPort)"
        } ?? "none"
        let summary = "Diagnostics: \(response.status?.profiles.count ?? 0) profiles, active ports \(activePorts)"
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct SSHAutoTunnelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTunnelIntent(profileName: "CERN lxplus"),
            phrases: ["Connect \(.applicationName) tunnel"],
            shortTitle: "Connect Tunnel",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(profileName: "CERN lxplus"),
            phrases: ["Disconnect \(.applicationName) tunnel"],
            shortTitle: "Disconnect Tunnel",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: ReconnectTunnelIntent(profileName: "CERN lxplus"),
            phrases: ["Reconnect \(.applicationName) tunnel"],
            shortTitle: "Reconnect Tunnel",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: TunnelStatusIntent(),
            phrases: ["Check \(.applicationName) status"],
            shortTitle: "Tunnel Status",
            systemImageName: "stethoscope"
        )
        AppShortcut(
            intent: PACURLIntent(),
            phrases: ["Get \(.applicationName) PAC URL"],
            shortTitle: "PAC URL",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: ReloadPACIntent(),
            phrases: ["Reload \(.applicationName) PAC"],
            shortTitle: "Reload PAC",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: ApplySystemPACIntent(),
            phrases: ["Apply \(.applicationName) system PAC"],
            shortTitle: "Apply System PAC",
            systemImageName: "network"
        )
        AppShortcut(
            intent: RestoreSystemProxyIntent(),
            phrases: ["Restore \(.applicationName) system proxy"],
            shortTitle: "Restore Proxy",
            systemImageName: "arrow.uturn.backward.circle"
        )
        AppShortcut(
            intent: ImportSSHAuto2FAIntent(),
            phrases: ["Import \(.applicationName) ssh auto two factor presets"],
            shortTitle: "Import ssh-auto2fa",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: CheckSSHAuto2FAIntent(),
            phrases: ["Check \(.applicationName) ssh auto two factor keychain"],
            shortTitle: "Check ssh-auto2fa",
            systemImageName: "key"
        )
        AppShortcut(
            intent: ImportSSHConfigIntent(),
            phrases: ["Import \(.applicationName) SSH config"],
            shortTitle: "Import SSH Config",
            systemImageName: "square.and.arrow.down.on.square"
        )
        AppShortcut(
            intent: CreateProfileIntent(),
            phrases: ["Create \(.applicationName) profile"],
            shortTitle: "Create Profile",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: UpdateProfileIntent(),
            phrases: ["Update \(.applicationName) profile"],
            shortTitle: "Update Profile",
            systemImageName: "pencil.circle"
        )
        AppShortcut(
            intent: DeleteProfileIntent(),
            phrases: ["Delete \(.applicationName) profile"],
            shortTitle: "Delete Profile",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: DiagnosticsIntent(),
            phrases: ["Get \(.applicationName) diagnostics"],
            shortTitle: "Diagnostics",
            systemImageName: "stethoscope"
        )
    }
}

private func api() throws -> ControlAPIClient {
    let configuration = try ConfigurationStore().load()
    return ControlAPIClient(configuration: configuration)
}

private func optionalString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func label(for state: KeychainCredentialState) -> String {
    switch state {
    case .available: "found"
    case .missing: "missing"
    case .unreadable(let message): "unreadable: \(message)"
    }
}
