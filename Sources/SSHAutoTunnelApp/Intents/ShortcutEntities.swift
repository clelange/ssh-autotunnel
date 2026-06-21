import AppIntents
import Foundation
import SSHAutoTunnelCore

enum ShortcutPACFailureMode: String, AppEnum {
    case failClosed
    case directFallback

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "PAC Failure Mode")

    static var caseDisplayRepresentations: [ShortcutPACFailureMode: DisplayRepresentation] = [
        .failClosed: "Fail Closed",
        .directFallback: "Direct Fallback"
    ]

    var coreValue: PACFailureMode {
        switch self {
        case .failClosed:
            .failClosed
        case .directFallback:
            .directFallback
        }
    }
}

enum ShortcutNetworkPolicyAction: String, AppEnum {
    case disableProxy
    case allowProxy

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Network Policy Action")

    static var caseDisplayRepresentations: [ShortcutNetworkPolicyAction: DisplayRepresentation] = [
        .disableProxy: "Disable Proxy",
        .allowProxy: "Allow Proxy"
    ]

    var coreValue: NetworkPolicyAction {
        switch self {
        case .disableProxy:
            .disableProxy
        case .allowProxy:
            .allowProxy
        }
    }
}

enum ShortcutProfileNotificationPolicy: String, AppEnum {
    case disabled
    case failuresAndRecoveries
    case allStatusChanges

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile Notification Policy")

    static var caseDisplayRepresentations: [ShortcutProfileNotificationPolicy: DisplayRepresentation] = [
        .disabled: "Disabled",
        .failuresAndRecoveries: "Failures and Recoveries",
        .allStatusChanges: "All Status Changes"
    ]

    var coreValue: ProfileNotificationPolicy {
        switch self {
        case .disabled:
            .disabled
        case .failuresAndRecoveries:
            .failuresAndRecoveries
        case .allStatusChanges:
            .allStatusChanges
        }
    }
}

enum ShortcutSSHLogLevel: String, AppEnum {
    case info
    case debug1
    case debug2
    case debug3

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "SSH Log Level")

    static var caseDisplayRepresentations: [ShortcutSSHLogLevel: DisplayRepresentation] = [
        .info: "INFO",
        .debug1: "DEBUG1",
        .debug2: "DEBUG2",
        .debug3: "DEBUG3"
    ]

    var coreValue: SSHLogLevel {
        switch self {
        case .info:
            .info
        case .debug1:
            .debug1
        case .debug2:
            .debug2
        case .debug3:
            .debug3
        }
    }
}

enum ShortcutSSHAddressFamily: String, AppEnum {
    case any
    case ipv4
    case ipv6

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "SSH Address Family")

    static var caseDisplayRepresentations: [ShortcutSSHAddressFamily: DisplayRepresentation] = [
        .any: "Any",
        .ipv4: "IPv4",
        .ipv6: "IPv6"
    ]

    var coreValue: SSHAddressFamily {
        switch self {
        case .any:
            .any
        case .ipv4:
            .ipv4
        case .ipv6:
            .ipv6
        }
    }
}

enum ShortcutSSHOptionToggle: String, AppEnum {
    case systemDefault
    case enabled
    case disabled

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "SSH Option Toggle")

    static var caseDisplayRepresentations: [ShortcutSSHOptionToggle: DisplayRepresentation] = [
        .systemDefault: "Default",
        .enabled: "Yes",
        .disabled: "No"
    ]

    var coreValue: SSHOptionToggle {
        switch self {
        case .systemDefault:
            .systemDefault
        case .enabled:
            .enabled
        case .disabled:
            .disabled
        }
    }
}

struct ShortcutTunnelProfileEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "SSH AutoTunnel Profile")
    static var defaultQuery = ShortcutTunnelProfileQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Host")
    var host: String

    @Property(title: "Interactive Host")
    var interactiveHost: String

    @Property(title: "Local SOCKS Port")
    var localSocksPort: Int

    @Property(title: "SSH Port")
    var sshPort: Int

    @Property(title: "User")
    var user: String

    @Property(title: "Jump Host")
    var jumpHost: String

    @Property(title: "Tags")
    var tags: String

    @Property(title: "SSH Log Level")
    var sshLogLevel: String

    @Property(title: "Connect on Launch")
    var connectOnLaunch: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(host):\(localSocksPort)"
        )
    }

    init(
        id: String,
        name: String,
        host: String,
        interactiveHost: String,
        localSocksPort: Int,
        sshPort: Int,
        user: String,
        jumpHost: String,
        tags: String,
        sshLogLevel: String,
        connectOnLaunch: Bool
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.interactiveHost = interactiveHost
        self.localSocksPort = localSocksPort
        self.sshPort = sshPort
        self.user = user
        self.jumpHost = jumpHost
        self.tags = tags
        self.sshLogLevel = sshLogLevel
        self.connectOnLaunch = connectOnLaunch
    }

    init(profile: TunnelProfile) {
        self.init(
            id: profile.id.uuidString,
            name: profile.name,
            host: profile.host,
            interactiveHost: profile.interactiveHost ?? "",
            localSocksPort: profile.localSocksPort,
            sshPort: profile.sshPort,
            user: profile.user ?? "",
            jumpHost: profile.jumpHost ?? "",
            tags: profile.tags.joined(separator: ", "),
            sshLogLevel: profile.sshLogLevel.displayName,
            connectOnLaunch: profile.connectOnLaunch
        )
    }

    static var placeholder: ShortcutTunnelProfileEntity {
        ShortcutTunnelProfileEntity(
            id: "",
            name: "Select profile",
            host: "",
            interactiveHost: "",
            localSocksPort: 0,
            sshPort: 22,
            user: "",
            jumpHost: "",
            tags: "",
            sshLogLevel: SSHLogLevel.info.displayName,
            connectOnLaunch: false
        )
    }
}

struct ShortcutPACRuleEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "SSH AutoTunnel PAC Rule")
    static var defaultQuery = ShortcutPACRuleQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Domain Pattern")
    var domainPattern: String

    @Property(title: "Profile Name")
    var profileName: String

    @Property(title: "Enabled")
    var enabled: Bool

    @Property(title: "Failure Mode")
    var failureMode: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(domainPattern) -> \(profileName)"
        )
    }

    init(
        id: String,
        name: String,
        domainPattern: String,
        profileName: String,
        enabled: Bool,
        failureMode: String
    ) {
        self.id = id
        self.name = name
        self.domainPattern = domainPattern
        self.profileName = profileName
        self.enabled = enabled
        self.failureMode = failureMode
    }

    init(rule: PACRule, configuration: AppConfiguration) {
        let profileName = configuration.profiles.first { $0.id == rule.profileID }?.name ?? "Missing profile"
        self.init(
            id: rule.id.uuidString,
            name: rule.name,
            domainPattern: rule.domainPattern,
            profileName: profileName,
            enabled: rule.enabled,
            failureMode: rule.failureMode.displayName
        )
    }

    static var placeholder: ShortcutPACRuleEntity {
        ShortcutPACRuleEntity(
            id: "",
            name: "Select PAC rule",
            domainPattern: "",
            profileName: "",
            enabled: true,
            failureMode: PACFailureMode.failClosed.displayName
        )
    }
}

struct ShortcutNetworkRuleEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "SSH AutoTunnel Network Rule")
    static var defaultQuery = ShortcutNetworkRuleQuery()

    var id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Match")
    var matchSummary: String

    @Property(title: "Action")
    var action: String

    @Property(title: "Profile Name")
    var profileName: String

    @Property(title: "Enabled")
    var enabled: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(matchSummary) -> \(profileName.isEmpty ? "all profiles" : profileName)"
        )
    }

    init(
        id: String,
        name: String,
        matchSummary: String,
        action: String,
        profileName: String,
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.matchSummary = matchSummary
        self.action = action
        self.profileName = profileName
        self.enabled = enabled
    }

    init(rule: NetworkPolicyRule, configuration: AppConfiguration) {
        let profileName = rule.profileID.flatMap { profileID in
            configuration.profiles.first { $0.id == profileID }?.name ?? "Missing profile"
        } ?? ""
        self.init(
            id: rule.id.uuidString,
            name: rule.name,
            matchSummary: AutomationSummaries.networkMatchSummary(rule.match),
            action: AutomationSummaries.networkActionName(rule.action),
            profileName: profileName,
            enabled: rule.enabled
        )
    }

    static var placeholder: ShortcutNetworkRuleEntity {
        ShortcutNetworkRuleEntity(
            id: "",
            name: "Select network rule",
            matchSummary: "",
            action: AutomationSummaries.networkActionName(.disableProxy),
            profileName: "",
            enabled: true
        )
    }
}

struct ShortcutTunnelProfileQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutTunnelProfileEntity] {
        let idSet = Set(identifiers)
        return try ShortcutEntityStore.profiles().filter { idSet.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ShortcutTunnelProfileEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try ShortcutEntityStore.profiles()
        }
        return try ShortcutEntityStore.profiles().filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || $0.user.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [ShortcutTunnelProfileEntity] {
        try ShortcutEntityStore.profiles()
    }
}

struct ShortcutPACRuleQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutPACRuleEntity] {
        let idSet = Set(identifiers)
        return try ShortcutEntityStore.pacRules().filter { idSet.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ShortcutPACRuleEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try ShortcutEntityStore.pacRules()
        }
        return try ShortcutEntityStore.pacRules().filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.domainPattern.localizedCaseInsensitiveContains(query)
                || $0.profileName.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [ShortcutPACRuleEntity] {
        try ShortcutEntityStore.pacRules()
    }
}

struct ShortcutNetworkRuleQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ShortcutNetworkRuleEntity] {
        let idSet = Set(identifiers)
        return try ShortcutEntityStore.networkRules().filter { idSet.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ShortcutNetworkRuleEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try ShortcutEntityStore.networkRules()
        }
        return try ShortcutEntityStore.networkRules().filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.matchSummary.localizedCaseInsensitiveContains(query)
                || $0.profileName.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [ShortcutNetworkRuleEntity] {
        try ShortcutEntityStore.networkRules()
    }
}

enum ShortcutEntityStore {
    static func configuration() throws -> AppConfiguration {
        try ConfigurationStore().load()
    }

    static func profiles(configuration: AppConfiguration? = nil) throws -> [ShortcutTunnelProfileEntity] {
        let resolvedConfiguration = try configuration ?? self.configuration()
        return resolvedConfiguration.profiles.map(ShortcutTunnelProfileEntity.init(profile:))
    }

    static func pacRules(configuration: AppConfiguration? = nil) throws -> [ShortcutPACRuleEntity] {
        let resolvedConfiguration = try configuration ?? self.configuration()
        return resolvedConfiguration.pacRules.map { ShortcutPACRuleEntity(rule: $0, configuration: resolvedConfiguration) }
    }

    static func networkRules(configuration: AppConfiguration? = nil) throws -> [ShortcutNetworkRuleEntity] {
        let resolvedConfiguration = try configuration ?? self.configuration()
        return resolvedConfiguration.networkRules.map { ShortcutNetworkRuleEntity(rule: $0, configuration: resolvedConfiguration) }
    }
}
