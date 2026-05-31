import AppIntents
import Foundation
import SSHAutoTunnelCore

struct ConnectSelectedTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Selected SSH Tunnel"
    static var description = IntentDescription("Connect an SSH AutoTunnel profile selected from the current configuration.")

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    init() {
        profile = .placeholder
    }

    init(profile: ShortcutTunnelProfileEntity) {
        self.profile = profile
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(ControlRequest(action: .connect, profileName: profile.name, profileID: try shortcutUUID(profile.id)))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DisconnectSelectedTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Selected SSH Tunnel"
    static var description = IntentDescription("Disconnect an SSH AutoTunnel profile selected from the current configuration.")

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    init() {
        profile = .placeholder
    }

    init(profile: ShortcutTunnelProfileEntity) {
        self.profile = profile
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(ControlRequest(action: .disconnect, profileName: profile.name, profileID: try shortcutUUID(profile.id)))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ReconnectSelectedTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Reconnect Selected SSH Tunnel"
    static var description = IntentDescription("Reconnect an SSH AutoTunnel profile selected from the current configuration.")

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    init() {
        profile = .placeholder
    }

    init(profile: ShortcutTunnelProfileEntity) {
        self.profile = profile
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(ControlRequest(action: .reconnect, profileName: profile.name, profileID: try shortcutUUID(profile.id)))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ConnectSelectedHopIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Selected SSH Hop"
    static var description = IntentDescription("Connect the jump host for a selected SSH AutoTunnel profile.")

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    init() {
        profile = .placeholder
    }

    init(profile: ShortcutTunnelProfileEntity) {
        self.profile = profile
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(ControlRequest(action: .connectHop, profileName: profile.name, profileID: try shortcutUUID(profile.id)))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DisconnectSelectedHopIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Selected SSH Hop"
    static var description = IntentDescription("Disconnect the jump host for a selected SSH AutoTunnel profile.")

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    init() {
        profile = .placeholder
    }

    init(profile: ShortcutTunnelProfileEntity) {
        self.profile = profile
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(ControlRequest(action: .disconnectHop, profileName: profile.name, profileID: try shortcutUUID(profile.id)))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ReconnectSelectedHopIntent: AppIntent {
    static var title: LocalizedStringResource = "Reconnect Selected SSH Hop"
    static var description = IntentDescription("Reconnect the jump host for a selected SSH AutoTunnel profile.")

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    init() {
        profile = .placeholder
    }

    init(profile: ShortcutTunnelProfileEntity) {
        self.profile = profile
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(ControlRequest(action: .reconnectHop, profileName: profile.name, profileID: try shortcutUUID(profile.id)))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DeleteSelectedProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Selected SSH AutoTunnel Profile"
    static var description = IntentDescription("Delete an SSH AutoTunnel profile selected from the current configuration.")

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    @Parameter(title: "Delete Keychain Items")
    var deleteKeychainItems: Bool

    init() {
        profile = .placeholder
        deleteKeychainItems = false
    }

    init(profile: ShortcutTunnelProfileEntity, deleteKeychainItems: Bool = false) {
        self.profile = profile
        self.deleteKeychainItems = deleteKeychainItems
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(
            ControlRequest(
                action: .deleteProfile,
                profileName: profile.name,
                profileID: try shortcutUUID(profile.id),
                deleteKeychainItems: deleteKeychainItems
            )
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct CreatePACRuleForSelectedProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Create PAC Rule for Selected Profile"
    static var description = IntentDescription("Create a PAC routing rule for a selected SSH AutoTunnel profile.")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Domain Pattern")
    var domainPattern: String

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    @Parameter(title: "Failure Mode")
    var failureMode: ShortcutPACFailureMode

    init() {
        name = "New routing"
        domainPattern = "*.example.org"
        profile = .placeholder
        failureMode = .failClosed
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rule = PACRule(
            name: name,
            domainPattern: domainPattern,
            profileID: try shortcutUUID(profile.id),
            failureMode: failureMode.coreValue
        )
        let response = try await shortcutAPI().send(ControlRequest(action: .createPACRule, pacRule: rule))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct UpdateSelectedPACRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Selected PAC Rule"
    static var description = IntentDescription("Update a PAC routing rule selected from the current configuration.")

    @Parameter(title: "PAC Rule")
    var rule: ShortcutPACRuleEntity

    @Parameter(title: "Domain Pattern")
    var domainPattern: String

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    @Parameter(title: "Failure Mode")
    var failureMode: ShortcutPACFailureMode

    @Parameter(title: "Enabled")
    var enabled: Bool

    init() {
        rule = .placeholder
        domainPattern = "*.example.org"
        profile = .placeholder
        failureMode = .failClosed
        enabled = true
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let replacement = PACRule(
            name: rule.name,
            domainPattern: domainPattern,
            profileID: try shortcutUUID(profile.id),
            enabled: enabled,
            failureMode: failureMode.coreValue
        )
        let response = try await shortcutAPI().send(
            ControlRequest(
                action: .updatePACRule,
                pacRuleName: rule.name,
                pacRuleID: try shortcutUUID(rule.id),
                pacRule: replacement
            )
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DeleteSelectedPACRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Selected PAC Rule"
    static var description = IntentDescription("Delete a PAC routing rule selected from the current configuration.")

    @Parameter(title: "PAC Rule")
    var rule: ShortcutPACRuleEntity

    init() {
        rule = .placeholder
    }

    init(rule: ShortcutPACRuleEntity) {
        self.rule = rule
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(
            ControlRequest(action: .deletePACRule, pacRuleName: rule.name, pacRuleID: try shortcutUUID(rule.id))
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct CreateNetworkRuleForSelectedProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Network Rule for Selected Profile"
    static var description = IntentDescription("Create a scoped trusted-network rule for a selected SSH AutoTunnel profile.")

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

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    @Parameter(title: "Action")
    var action: ShortcutNetworkPolicyAction

    init() {
        name = "Trusted network"
        wifiSSID = ""
        searchDomainContains = "example.org"
        serviceNameContains = ""
        gateway = ""
        profile = .placeholder
        action = .disableProxy
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rule = NetworkPolicyRule(
            name: name,
            match: try shortcutNetworkMatch(
                wifiSSID: wifiSSID,
                searchDomainContains: searchDomainContains,
                serviceNameContains: serviceNameContains,
                gateway: gateway
            ),
            action: action.coreValue,
            profileID: try shortcutUUID(profile.id)
        )
        let response = try await shortcutAPI().send(ControlRequest(action: .createNetworkRule, networkRule: rule))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct UpdateSelectedNetworkRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Update Selected Network Rule"
    static var description = IntentDescription("Update a trusted-network rule selected from the current configuration.")

    @Parameter(title: "Network Rule")
    var rule: ShortcutNetworkRuleEntity

    @Parameter(title: "Wi-Fi SSID")
    var wifiSSID: String

    @Parameter(title: "Search Domain Contains")
    var searchDomainContains: String

    @Parameter(title: "Service Name Contains")
    var serviceNameContains: String

    @Parameter(title: "Gateway")
    var gateway: String

    @Parameter(title: "Profile")
    var profile: ShortcutTunnelProfileEntity

    @Parameter(title: "Action")
    var action: ShortcutNetworkPolicyAction

    @Parameter(title: "Enabled")
    var enabled: Bool

    init() {
        rule = .placeholder
        wifiSSID = ""
        searchDomainContains = "example.org"
        serviceNameContains = ""
        gateway = ""
        profile = .placeholder
        action = .disableProxy
        enabled = true
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let replacement = NetworkPolicyRule(
            name: rule.name,
            enabled: enabled,
            match: try shortcutNetworkMatch(
                wifiSSID: wifiSSID,
                searchDomainContains: searchDomainContains,
                serviceNameContains: serviceNameContains,
                gateway: gateway
            ),
            action: action.coreValue,
            profileID: try shortcutUUID(profile.id)
        )
        let response = try await shortcutAPI().send(
            ControlRequest(
                action: .updateNetworkRule,
                networkRuleName: rule.name,
                networkRuleID: try shortcutUUID(rule.id),
                networkRule: replacement
            )
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DeleteSelectedNetworkRuleIntent: AppIntent {
    static var title: LocalizedStringResource = "Delete Selected Network Rule"
    static var description = IntentDescription("Delete a trusted-network rule selected from the current configuration.")

    @Parameter(title: "Network Rule")
    var rule: ShortcutNetworkRuleEntity

    init() {
        rule = .placeholder
    }

    init(rule: ShortcutNetworkRuleEntity) {
        self.rule = rule
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await shortcutAPI().send(
            ControlRequest(action: .deleteNetworkRule, networkRuleName: rule.name, networkRuleID: try shortcutUUID(rule.id))
        )
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct ListProfilesIntent: AppIntent {
    static var title: LocalizedStringResource = "List SSH AutoTunnel Profiles"
    static var description = IntentDescription("Return the configured SSH AutoTunnel profiles.")

    func perform() async throws -> some IntentResult & ReturnsValue<[ShortcutTunnelProfileEntity]> & ProvidesDialog {
        let profiles = try ShortcutEntityStore.profiles()
        let summary = profiles.isEmpty ? "No profiles configured" : profiles.map(\.name).joined(separator: ", ")
        return .result(value: profiles, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct ListPACRulesIntent: AppIntent {
    static var title: LocalizedStringResource = "List SSH AutoTunnel PAC Rules"
    static var description = IntentDescription("Return the configured SSH AutoTunnel PAC routing rules.")

    func perform() async throws -> some IntentResult & ReturnsValue<[ShortcutPACRuleEntity]> & ProvidesDialog {
        let rules = try ShortcutEntityStore.pacRules()
        let summary = rules.isEmpty ? "No PAC rules configured" : rules.map(\.name).joined(separator: ", ")
        return .result(value: rules, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct ListNetworkRulesIntent: AppIntent {
    static var title: LocalizedStringResource = "List SSH AutoTunnel Network Rules"
    static var description = IntentDescription("Return the configured SSH AutoTunnel trusted-network rules.")

    func perform() async throws -> some IntentResult & ReturnsValue<[ShortcutNetworkRuleEntity]> & ProvidesDialog {
        let rules = try ShortcutEntityStore.networkRules()
        let summary = rules.isEmpty ? "No network rules configured" : rules.map(\.name).joined(separator: ", ")
        return .result(value: rules, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct CurrentNetworkFingerprintIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel Current Network"
    static var description = IntentDescription("Return the current network fingerprint used by SSH AutoTunnel network rules.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let fingerprint = NetworkIdentityService().currentFingerprint()
        let summary = AutomationSummaries.currentNetworkSummary(fingerprint)
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary.isEmpty ? "No network fingerprint data available" : summary))
    }
}

private func shortcutAPI(configuration: AppConfiguration? = nil) throws -> ControlAPIClient {
    let resolvedConfiguration = try configuration ?? ShortcutEntityStore.configuration()
    return ControlAPIClient(configuration: resolvedConfiguration)
}

private func shortcutUUID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
        throw shortcutIntentError("Invalid identifier: \(value)")
    }
    return id
}

private func shortcutNetworkMatch(
    wifiSSID: String,
    searchDomainContains: String,
    serviceNameContains: String,
    gateway: String
) throws -> NetworkMatch {
    let match = NetworkMatch(
        wifiSSID: shortcutOptionalString(wifiSSID),
        serviceNameContains: shortcutOptionalString(serviceNameContains),
        searchDomainContains: shortcutOptionalString(searchDomainContains),
        gateway: shortcutOptionalString(gateway)
    )
    guard match.wifiSSID != nil || match.serviceNameContains != nil || match.searchDomainContains != nil || match.gateway != nil else {
        throw shortcutIntentError("At least one network match field is required.")
    }
    return match
}

private func shortcutOptionalString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func shortcutIntentError(_ message: String) -> NSError {
    NSError(domain: "dev.clange.ssh-autotunnel.app-intents", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
