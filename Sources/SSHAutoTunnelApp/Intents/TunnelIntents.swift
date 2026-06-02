import AppIntents
import Foundation
import SSHAutoTunnelCore

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect SSH Tunnel"
    static var description = IntentDescription("Connect an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "CERN LxPlus"
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
        profileName = "CERN LxPlus"
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
        profileName = "CERN LxPlus"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .reconnect, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ConnectHopIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect SSH Hop"
    static var description = IntentDescription("Connect the jump host for an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "PSI General"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .connectHop, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DisconnectHopIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect SSH Hop"
    static var description = IntentDescription("Disconnect the jump host for an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "PSI General"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .disconnectHop, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ReconnectHopIntent: AppIntent {
    static var title: LocalizedStringResource = "Reconnect SSH Hop"
    static var description = IntentDescription("Reconnect the jump host for an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "PSI General"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .reconnectHop, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct TunnelStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel Status"
    static var description = IntentDescription("Get the current SSH AutoTunnel status.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .status))
        let summary = response.status?.profiles.map { profile in
            if let hop = profile.hop {
                return "\(profile.name): tunnel \(profile.health.rawValue), hop \(hop.health.rawValue)"
            }
            return "\(profile.name): \(profile.health.rawValue)"
        }.joined(separator: ", ") ?? response.message
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct PACURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel PAC URL"
    static var description = IntentDescription("Get the local PAC URL for SSH AutoTunnel.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .pacURL))
        return .result(value: response.message, dialog: IntentDialog(stringLiteral: response.message))
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

    @Parameter(title: "Interactive Host")
    var interactiveHost: String

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
        interactiveHost = ""
        localSocksPort = 1083
        sshPort = 22
        user = ""
        jumpHost = ""
    }

    init(name: String, host: String, interactiveHost: String = "", localSocksPort: Int, sshPort: Int = 22, user: String = "", jumpHost: String = "") {
        self.name = name
        self.host = host
        self.interactiveHost = interactiveHost
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
            interactiveHost: optionalString(interactiveHost),
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

    @Parameter(title: "Interactive Host")
    var interactiveHost: String

    @Parameter(title: "Local SOCKS Port")
    var localSocksPort: Int

    @Parameter(title: "SSH Port")
    var sshPort: Int

    @Parameter(title: "User")
    var user: String

    @Parameter(title: "Jump Host")
    var jumpHost: String

    init() {
        profileName = "CERN LxPlus"
        host = "lxplus.cern.ch"
        interactiveHost = ""
        localSocksPort = 1081
        sshPort = 22
        user = ""
        jumpHost = ""
    }

    init(profileName: String, host: String, interactiveHost: String = "", localSocksPort: Int, sshPort: Int = 22, user: String = "", jumpHost: String = "") {
        self.profileName = profileName
        self.host = host
        self.interactiveHost = interactiveHost
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
            interactiveHost: optionalString(interactiveHost),
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

    @Parameter(title: "Delete Keychain Items")
    var deleteKeychainItems: Bool

    init() {
        profileName = "Old tunnel"
        deleteKeychainItems = false
    }

    init(profileName: String, deleteKeychainItems: Bool = false) {
        self.profileName = profileName
        self.deleteKeychainItems = deleteKeychainItems
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(
            ControlRequest(
                action: .deleteProfile,
                profileName: profileName,
                deleteKeychainItems: deleteKeychainItems
            )
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct CreatePACRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Create SSH AutoTunnel PAC Rule"
    static var description = IntentDescription("Create a PAC routing rule from Shortcuts or Automations.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Domain Pattern")
    var domainPattern: String

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Failure Mode")
    var failureMode: String

    init() {
        name = "New routing"
        domainPattern = "*.example.org"
        profileName = "CERN LxPlus"
        failureMode = PACFailureMode.directFallback.rawValue
    }

    init(name: String, domainPattern: String, profileName: String, failureMode: String = PACFailureMode.directFallback.rawValue) {
        self.name = name
        self.domainPattern = domainPattern
        self.profileName = profileName
        self.failureMode = failureMode
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let configuration = try localConfiguration()
        let rule = PACRule(
            name: name,
            domainPattern: domainPattern,
            profileID: try profileID(named: profileName, in: configuration),
            failureMode: try pacFailureMode(from: failureMode)
        )
        let response = try await api(configuration: configuration).send(ControlRequest(action: .createPACRule, pacRule: rule))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct UpdatePACRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Update SSH AutoTunnel PAC Rule"
    static var description = IntentDescription("Update a PAC routing rule from Shortcuts or Automations.")

    @Parameter(title: "Rule Name")
    var ruleName: String

    @Parameter(title: "Domain Pattern")
    var domainPattern: String

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Failure Mode")
    var failureMode: String

    @Parameter(title: "Enabled")
    var enabled: Bool

    init() {
        ruleName = "CERN"
        domainPattern = "*.cern.ch"
        profileName = "CERN LxPlus"
        failureMode = PACFailureMode.directFallback.rawValue
        enabled = true
    }

    init(
        ruleName: String,
        domainPattern: String,
        profileName: String,
        failureMode: String = PACFailureMode.directFallback.rawValue,
        enabled: Bool = true
    ) {
        self.ruleName = ruleName
        self.domainPattern = domainPattern
        self.profileName = profileName
        self.failureMode = failureMode
        self.enabled = enabled
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let configuration = try localConfiguration()
        let rule = PACRule(
            name: ruleName,
            domainPattern: domainPattern,
            profileID: try profileID(named: profileName, in: configuration),
            enabled: enabled,
            failureMode: try pacFailureMode(from: failureMode)
        )
        let response = try await api(configuration: configuration).send(
            ControlRequest(action: .updatePACRule, pacRuleName: ruleName, pacRule: rule)
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DeletePACRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete SSH AutoTunnel PAC Rule"
    static var description = IntentDescription("Delete a PAC routing rule by name.")

    @Parameter(title: "Rule Name")
    var ruleName: String

    init() {
        ruleName = "Old routing"
    }

    init(ruleName: String) {
        self.ruleName = ruleName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .deletePACRule, pacRuleName: ruleName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct TrustCurrentNetworkIntent: AppIntent {
    static var title: LocalizedStringResource = "Trust Current SSH AutoTunnel Network"
    static var description = IntentDescription("Create a network policy rule from the current network fingerprint.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = ""
    }

    init(profileName: String = "") {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(
            ControlRequest(action: .createNetworkRuleFromCurrentNetwork, profileName: optionalString(profileName))
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct CreateNetworkRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Create SSH AutoTunnel Network Rule"
    static var description = IntentDescription("Create a trusted-network rule from Shortcuts or Automations.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Wi-Fi SSID")
    var wifiSSID: String

    @Parameter(title: "Search Domain Contains")
    var searchDomainContains: String

    @Parameter(title: "Service Name Contains")
    var serviceNameContains: String

    @Parameter(title: "Gateway")
    var gateway: String

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Action")
    var action: String

    init() {
        name = "Trusted network"
        wifiSSID = ""
        searchDomainContains = "example.org"
        serviceNameContains = ""
        gateway = ""
        profileName = ""
        action = NetworkPolicyAction.disableProxy.rawValue
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let configuration = try localConfiguration()
        let rule = NetworkPolicyRule(
            name: name,
            match: try networkMatch(
                wifiSSID: wifiSSID,
                searchDomainContains: searchDomainContains,
                serviceNameContains: serviceNameContains,
                gateway: gateway
            ),
            action: try networkPolicyAction(from: action),
            profileID: try optionalProfileID(named: profileName, in: configuration)
        )
        let response = try await api(configuration: configuration).send(ControlRequest(action: .createNetworkRule, networkRule: rule))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct UpdateNetworkRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Update SSH AutoTunnel Network Rule"
    static var description = IntentDescription("Update a trusted-network rule from Shortcuts or Automations.")

    @Parameter(title: "Rule Name")
    var ruleName: String

    @Parameter(title: "Wi-Fi SSID")
    var wifiSSID: String

    @Parameter(title: "Search Domain Contains")
    var searchDomainContains: String

    @Parameter(title: "Service Name Contains")
    var serviceNameContains: String

    @Parameter(title: "Gateway")
    var gateway: String

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Action")
    var action: String

    @Parameter(title: "Enabled")
    var enabled: Bool

    init() {
        ruleName = "Trusted network"
        wifiSSID = ""
        searchDomainContains = "example.org"
        serviceNameContains = ""
        gateway = ""
        profileName = ""
        action = NetworkPolicyAction.disableProxy.rawValue
        enabled = true
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let configuration = try localConfiguration()
        let rule = NetworkPolicyRule(
            name: ruleName,
            enabled: enabled,
            match: try networkMatch(
                wifiSSID: wifiSSID,
                searchDomainContains: searchDomainContains,
                serviceNameContains: serviceNameContains,
                gateway: gateway
            ),
            action: try networkPolicyAction(from: action),
            profileID: try optionalProfileID(named: profileName, in: configuration)
        )
        let response = try await api(configuration: configuration).send(
            ControlRequest(action: .updateNetworkRule, networkRuleName: ruleName, networkRule: rule)
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DeleteNetworkRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete SSH AutoTunnel Network Rule"
    static var description = IntentDescription("Delete a trusted-network rule by name.")

    @Parameter(title: "Rule Name")
    var ruleName: String

    init() {
        ruleName = "Old trusted network"
    }

    init(ruleName: String) {
        self.ruleName = ruleName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .deleteNetworkRule, networkRuleName: ruleName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DiagnosticsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel Diagnostics"
    static var description = IntentDescription("Get a structured SSH AutoTunnel diagnostics summary.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .diagnostics))
        let diagnostics = response.diagnostics
        let activePorts = diagnostics?.activePorts.map {
            "PAC \($0.pacHTTPPort), API \($0.apiHTTPPort), blocking proxy \($0.blockingHTTPProxyPort)"
        } ?? "none"
        let summary = "Diagnostics: \(response.status?.profiles.count ?? 0) profiles, active ports \(activePorts)"
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct ExportConfigurationIntent: AppIntent {
    static var title: LocalizedStringResource = "Export SSH AutoTunnel Configuration"
    static var description = IntentDescription("Return a redacted SSH AutoTunnel configuration export as JSON.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .exportConfiguration))
        guard response.ok, let export = response.configurationExport else {
            throw intentError(response.message)
        }
        let json = try automationJSONString(export)
        return .result(value: json, dialog: IntentDialog(stringLiteral: "Exported redacted configuration"))
    }
}

struct ImportConfigurationIntent: AppIntent {
    static var title: LocalizedStringResource = "Import SSH AutoTunnel Configuration"
    static var description = IntentDescription("Import a redacted SSH AutoTunnel configuration export from JSON.")

    @Parameter(title: "Configuration JSON")
    var configurationJSON: String

    init() {
        configurationJSON = ""
    }

    init(configurationJSON: String) {
        self.configurationJSON = configurationJSON
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let data = configurationJSON.data(using: .utf8) else {
            throw intentError("Configuration JSON is not valid UTF-8.")
        }
        let export = try JSONDecoder().decode(ConfigurationExport.self, from: data)
        let response = try await api().send(ControlRequest(action: .importConfiguration, configurationExport: export))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ValidateConfigurationIntent: AppIntent {
    static var title: LocalizedStringResource = "Validate SSH AutoTunnel Configuration"
    static var description = IntentDescription("Validate a redacted SSH AutoTunnel configuration export without applying it.")

    @Parameter(title: "Configuration JSON")
    var configurationJSON: String

    init() {
        configurationJSON = ""
    }

    init(configurationJSON: String) {
        self.configurationJSON = configurationJSON
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let data = configurationJSON.data(using: .utf8) else {
            throw intentError("Configuration JSON is not valid UTF-8.")
        }
        let export = try JSONDecoder().decode(ConfigurationExport.self, from: data)
        let response = try await api().send(ControlRequest(action: .validateConfigurationExport, configurationExport: export))
        let report = response.configurationValidation
        let summary = report.map {
            "\($0.message). Profiles: \($0.profileCount), PAC rules: \($0.pacRuleCount), network rules: \($0.networkRuleCount)"
        } ?? response.message
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct SupportBundleIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel Support Bundle"
    static var description = IntentDescription("Return a redacted SSH AutoTunnel support bundle as JSON.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .supportBundle))
        guard response.ok, let bundle = response.supportBundle else {
            throw intentError(response.message)
        }
        let json = try automationJSONString(bundle)
        let profileCount = bundle.configuration.profiles.count
        return .result(value: json, dialog: IntentDialog(stringLiteral: "Created support bundle for \(profileCount) profiles"))
    }
}

struct SSHAutoTunnelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTunnelIntent(profileName: "CERN LxPlus"),
            phrases: ["Connect \(.applicationName) tunnel"],
            shortTitle: "Connect Tunnel",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(profileName: "CERN LxPlus"),
            phrases: ["Disconnect \(.applicationName) tunnel"],
            shortTitle: "Disconnect Tunnel",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: ReconnectTunnelIntent(profileName: "CERN LxPlus"),
            phrases: ["Reconnect \(.applicationName) tunnel"],
            shortTitle: "Reconnect Tunnel",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: ConnectHopIntent(profileName: "PSI General"),
            phrases: ["Connect \(.applicationName) hop"],
            shortTitle: "Connect Hop",
            systemImageName: "point.3.connected.trianglepath.dotted"
        )
        AppShortcut(
            intent: DisconnectHopIntent(profileName: "PSI General"),
            phrases: ["Disconnect \(.applicationName) hop"],
            shortTitle: "Disconnect Hop",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: ReconnectHopIntent(profileName: "PSI General"),
            phrases: ["Reconnect \(.applicationName) hop"],
            shortTitle: "Reconnect Hop",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: TunnelStatusIntent(),
            phrases: ["Check \(.applicationName) status"],
            shortTitle: "Tunnel Status",
            systemImageName: "stethoscope"
        )
        AppShortcut(
            intent: ListProfilesIntent(),
            phrases: ["List \(.applicationName) profiles"],
            shortTitle: "List Profiles",
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: ListPACRulesIntent(),
            phrases: ["List \(.applicationName) PAC rules"],
            shortTitle: "List PAC Rules",
            systemImageName: "point.topleft.down.curvedto.point.bottomright.up"
        )
        AppShortcut(
            intent: ListNetworkRulesIntent(),
            phrases: ["List \(.applicationName) network rules"],
            shortTitle: "List Network Rules",
            systemImageName: "network"
        )
        AppShortcut(
            intent: CurrentNetworkFingerprintIntent(),
            phrases: ["Get current \(.applicationName) network"],
            shortTitle: "Current Network",
            systemImageName: "wifi"
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
            intent: ConnectSelectedTunnelIntent(),
            phrases: ["Connect selected \(.applicationName) tunnel"],
            shortTitle: "Connect Selected",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: DisconnectSelectedTunnelIntent(),
            phrases: ["Disconnect selected \(.applicationName) tunnel"],
            shortTitle: "Disconnect Selected",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: ReconnectSelectedTunnelIntent(),
            phrases: ["Reconnect selected \(.applicationName) tunnel"],
            shortTitle: "Reconnect Selected",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: ConnectSelectedHopIntent(),
            phrases: ["Connect selected \(.applicationName) hop"],
            shortTitle: "Connect Hop",
            systemImageName: "point.3.connected.trianglepath.dotted"
        )
        AppShortcut(
            intent: DisconnectSelectedHopIntent(),
            phrases: ["Disconnect selected \(.applicationName) hop"],
            shortTitle: "Disconnect Hop",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: ReconnectSelectedHopIntent(),
            phrases: ["Reconnect selected \(.applicationName) hop"],
            shortTitle: "Reconnect Hop",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: CreatePACRuleIntent(),
            phrases: ["Create \(.applicationName) PAC rule"],
            shortTitle: "Create PAC Rule",
            systemImageName: "point.topleft.down.curvedto.point.bottomright.up"
        )
        AppShortcut(
            intent: UpdatePACRuleIntent(),
            phrases: ["Update \(.applicationName) PAC rule"],
            shortTitle: "Update PAC Rule",
            systemImageName: "pencil.and.list.clipboard"
        )
        AppShortcut(
            intent: DeletePACRuleIntent(),
            phrases: ["Delete \(.applicationName) PAC rule"],
            shortTitle: "Delete PAC Rule",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: TrustCurrentNetworkIntent(),
            phrases: ["Trust current \(.applicationName) network"],
            shortTitle: "Trust Network",
            systemImageName: "wifi.router"
        )
        AppShortcut(
            intent: CreateNetworkRuleIntent(),
            phrases: ["Create \(.applicationName) network rule"],
            shortTitle: "Create Network Rule",
            systemImageName: "network"
        )
        AppShortcut(
            intent: UpdateNetworkRuleIntent(),
            phrases: ["Update \(.applicationName) network rule"],
            shortTitle: "Update Network Rule",
            systemImageName: "pencil.circle"
        )
        AppShortcut(
            intent: DeleteNetworkRuleIntent(),
            phrases: ["Delete \(.applicationName) network rule"],
            shortTitle: "Delete Network Rule",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: DiagnosticsIntent(),
            phrases: ["Get \(.applicationName) diagnostics"],
            shortTitle: "Diagnostics",
            systemImageName: "stethoscope"
        )
        AppShortcut(
            intent: ExportConfigurationIntent(),
            phrases: ["Export \(.applicationName) configuration"],
            shortTitle: "Export Config",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: ImportConfigurationIntent(),
            phrases: ["Import \(.applicationName) configuration"],
            shortTitle: "Import Config",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: ValidateConfigurationIntent(),
            phrases: ["Validate \(.applicationName) configuration"],
            shortTitle: "Validate Config",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: SupportBundleIntent(),
            phrases: ["Get \(.applicationName) support bundle"],
            shortTitle: "Support Bundle",
            systemImageName: "shippingbox"
        )
    }
}

private func localConfiguration() throws -> AppConfiguration {
    try ConfigurationStore().load()
}

private func api(configuration: AppConfiguration? = nil) throws -> ControlAPIClient {
    let configuration = try configuration ?? localConfiguration()
    return ControlAPIClient(configuration: configuration)
}

private func optionalString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func profileID(named name: String, in configuration: AppConfiguration) throws -> UUID {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let profile = configuration.profiles.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) else {
        throw intentError("Profile not found: \(trimmedName)")
    }
    return profile.id
}

private func optionalProfileID(named name: String, in configuration: AppConfiguration) throws -> UUID? {
    guard let name = optionalString(name) else { return nil }
    return try profileID(named: name, in: configuration)
}

private func pacFailureMode(from value: String) throws -> PACFailureMode {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
        return .failClosed
    }
    if let mode = PACFailureMode(rawValue: normalized) {
        return mode
    }
    switch normalized.lowercased() {
    case "fail closed", "fail-closed":
        return .failClosed
    case "direct fallback", "direct-fallback":
        return .directFallback
    default:
        throw intentError("Unknown PAC failure mode: \(value)")
    }
}

private func networkPolicyAction(from value: String) throws -> NetworkPolicyAction {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
        return .disableProxy
    }
    if let action = NetworkPolicyAction(rawValue: normalized) {
        return action
    }
    switch normalized.lowercased() {
    case "disable proxy", "disable-proxy":
        return .disableProxy
    case "allow proxy", "allow-proxy":
        return .allowProxy
    default:
        throw intentError("Unknown network policy action: \(value)")
    }
}

private func networkMatch(
    wifiSSID: String,
    searchDomainContains: String,
    serviceNameContains: String,
    gateway: String
) throws -> NetworkMatch {
    let match = NetworkMatch(
        wifiSSID: optionalString(wifiSSID),
        serviceNameContains: optionalString(serviceNameContains),
        searchDomainContains: optionalString(searchDomainContains),
        gateway: optionalString(gateway)
    )
    guard match.wifiSSID != nil || match.serviceNameContains != nil || match.searchDomainContains != nil || match.gateway != nil else {
        throw intentError("At least one network match field is required.")
    }
    return match
}

private func intentError(_ message: String) -> NSError {
    NSError(domain: "dev.clange.ssh-autotunnel.app-intents", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func automationJSONString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw intentError("Could not encode JSON.")
    }
    return json
}

private func label(for state: KeychainCredentialState) -> String {
    switch state {
    case .available: "found"
    case .missing: "missing"
    case .unreadable(let message): "unreadable: \(message)"
    }
}
