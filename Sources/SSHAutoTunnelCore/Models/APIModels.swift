import Foundation

public enum ControlAction: String, Codable, Sendable {
    case connect
    case disconnect
    case reconnect
    case connectHop
    case disconnectHop
    case reconnectHop
    case status
    case pacURL
    case reloadPAC
    case applySystemPAC
    case restoreSystemPAC
    case importSSHAuto2FA
    case checkSSHAuto2FA
    case importSSHConfig
    case checkSSHConfig
    case createProfile
    case updateProfile
    case deleteProfile
    case createPACRule
    case updatePACRule
    case deletePACRule
    case createNetworkRule
    case updateNetworkRule
    case deleteNetworkRule
    case createNetworkRuleFromCurrentNetwork
    case diagnostics
    case exportConfiguration
    case importConfiguration
    case validateConfigurationExport
    case supportBundle
}

public struct ControlRequest: Codable, Sendable {
    public var action: ControlAction
    public var profileName: String?
    public var profileID: UUID?
    public var deleteKeychainItems: Bool?
    public var profile: TunnelProfile?
    public var pacRuleName: String?
    public var pacRuleID: UUID?
    public var pacRule: PACRule?
    public var networkRuleName: String?
    public var networkRuleID: UUID?
    public var networkRule: NetworkPolicyRule?
    public var configurationExport: ConfigurationExport?

    public init(
        action: ControlAction,
        profileName: String? = nil,
        profileID: UUID? = nil,
        deleteKeychainItems: Bool? = nil,
        profile: TunnelProfile? = nil,
        pacRuleName: String? = nil,
        pacRuleID: UUID? = nil,
        pacRule: PACRule? = nil,
        networkRuleName: String? = nil,
        networkRuleID: UUID? = nil,
        networkRule: NetworkPolicyRule? = nil,
        configurationExport: ConfigurationExport? = nil
    ) {
        self.action = action
        self.profileName = profileName
        self.profileID = profileID
        self.deleteKeychainItems = deleteKeychainItems
        self.profile = profile
        self.pacRuleName = pacRuleName
        self.pacRuleID = pacRuleID
        self.pacRule = pacRule
        self.networkRuleName = networkRuleName
        self.networkRuleID = networkRuleID
        self.networkRule = networkRule
        self.configurationExport = configurationExport
    }
}

public struct ProfileStatusSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var interactiveHost: String?
    public var jumpHost: String?
    public var user: String?
    public var sshPort: Int
    public var tags: [String]
    public var localSocksPort: Int
    public var effectiveLocalSocksPort: Int?
    public var localPortForwardings: [LocalPortForward]
    public var tunnelRequestsRemoteSession: Bool
    public var curatedSSHOptions: CuratedSSHOptions
    public var connectOnLaunch: Bool
    public var autoReconnect: Bool
    public var notificationPolicy: ProfileNotificationPolicy
    public var sshLogLevel: SSHLogLevel
    public var hop: HopStatusSnapshot?
    public var health: TunnelHealth
    public var message: String
    public var pid: Int32?

    public init(profile: TunnelProfile, status: TunnelRuntimeStatus, hopStatus: HopRuntimeStatus? = nil) {
        id = profile.id
        name = profile.name
        host = profile.host
        interactiveHost = profile.interactiveHost
        jumpHost = profile.jumpHost
        user = profile.user
        sshPort = profile.sshPort
        tags = profile.tags
        localSocksPort = profile.localSocksPort
        effectiveLocalSocksPort = status.effectiveLocalSocksPort
        localPortForwardings = profile.localPortForwardings
        tunnelRequestsRemoteSession = profile.tunnelRequestsRemoteSession
        curatedSSHOptions = profile.curatedSSHOptions
        connectOnLaunch = profile.connectOnLaunch
        autoReconnect = profile.autoReconnect
        notificationPolicy = profile.notificationPolicy
        sshLogLevel = profile.sshLogLevel
        hop = hopStatus.map(HopStatusSnapshot.init(status:))
        health = status.health
        message = status.message
        pid = status.pid
    }
}

public struct HopStatusSnapshot: Codable, Equatable, Sendable {
    public var jumpHost: String
    public var health: TunnelHealth
    public var message: String
    public var pid: Int32?
    public var ownership: HopMasterOwnership?
    public var issue: HopConnectionIssue?

    public init(status: HopRuntimeStatus) {
        jumpHost = status.jumpHost
        health = status.health
        message = status.message
        pid = status.pid
        ownership = status.ownership
        issue = status.issue
    }
}

public struct AppStatusSnapshot: Codable, Equatable, Sendable {
    public var pacURL: String
    public var systemPACStatus: SystemPACStatus?
    public var proxyDisabledByNetworkPolicy: Bool
    public var matchedNetworkRule: String?
    public var networkDisabledProfileIDs: [UUID]
    public var directAccessProfileIDs: [UUID]
    public var matchedDirectAccessRules: [String]
    public var profiles: [ProfileStatusSnapshot]

    public init(
        pacURL: String,
        systemPACStatus: SystemPACStatus? = nil,
        proxyDisabledByNetworkPolicy: Bool,
        matchedNetworkRule: String?,
        networkDisabledProfileIDs: [UUID] = [],
        directAccessProfileIDs: [UUID] = [],
        matchedDirectAccessRules: [String] = [],
        profiles: [ProfileStatusSnapshot]
    ) {
        self.pacURL = pacURL
        self.systemPACStatus = systemPACStatus
        self.proxyDisabledByNetworkPolicy = proxyDisabledByNetworkPolicy
        self.matchedNetworkRule = matchedNetworkRule
        self.networkDisabledProfileIDs = networkDisabledProfileIDs
        self.directAccessProfileIDs = directAccessProfileIDs
        self.matchedDirectAccessRules = matchedDirectAccessRules
        self.profiles = profiles
    }
}

public struct DiagnosticFileStatus: Codable, Equatable, Sendable {
    public var label: String
    public var path: String
    public var exists: Bool
    public var posixPermissions: String?
    public var isPrivate: Bool

    public init(
        label: String,
        path: String,
        exists: Bool,
        posixPermissions: String?,
        isPrivate: Bool
    ) {
        self.label = label
        self.path = path
        self.exists = exists
        self.posixPermissions = posixPermissions
        self.isPrivate = isPrivate
    }
}

public struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var appIdentifier: String
    public var pacURL: String
    public var statusURL: String
    public var proxyApplyMode: ProxyApplyMode
    public var systemPACStatus: SystemPACStatus?
    public var proxyDisabledByNetworkPolicy: Bool
    public var matchedNetworkRule: String?
    public var networkDisabledProfileIDs: [UUID]
    public var directAccessProfileIDs: [UUID]
    public var matchedDirectAccessRules: [String]
    public var configuredPorts: LocalServerPorts
    public var activePorts: LocalServerPorts?
    public var currentNetwork: NetworkFingerprint
    public var profiles: [ProfileStatusSnapshot]
    public var fileStatuses: [DiagnosticFileStatus]
    public var systemProxySnapshotExists: Bool

    public init(
        generatedAt: Date = Date(),
        appIdentifier: String,
        pacURL: String,
        statusURL: String,
        proxyApplyMode: ProxyApplyMode,
        systemPACStatus: SystemPACStatus? = nil,
        proxyDisabledByNetworkPolicy: Bool,
        matchedNetworkRule: String?,
        networkDisabledProfileIDs: [UUID] = [],
        directAccessProfileIDs: [UUID] = [],
        matchedDirectAccessRules: [String] = [],
        configuredPorts: LocalServerPorts,
        activePorts: LocalServerPorts?,
        currentNetwork: NetworkFingerprint,
        profiles: [ProfileStatusSnapshot],
        fileStatuses: [DiagnosticFileStatus],
        systemProxySnapshotExists: Bool
    ) {
        self.generatedAt = generatedAt
        self.appIdentifier = appIdentifier
        self.pacURL = pacURL
        self.statusURL = statusURL
        self.proxyApplyMode = proxyApplyMode
        self.systemPACStatus = systemPACStatus
        self.proxyDisabledByNetworkPolicy = proxyDisabledByNetworkPolicy
        self.matchedNetworkRule = matchedNetworkRule
        self.networkDisabledProfileIDs = networkDisabledProfileIDs
        self.directAccessProfileIDs = directAccessProfileIDs
        self.matchedDirectAccessRules = matchedDirectAccessRules
        self.configuredPorts = configuredPorts
        self.activePorts = activePorts
        self.currentNetwork = currentNetwork
        self.profiles = profiles
        self.fileStatuses = fileStatuses
        self.systemProxySnapshotExists = systemProxySnapshotExists
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var status: AppStatusSnapshot?
    public var sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus]?
    public var diagnostics: DiagnosticsSnapshot?
    public var configurationExport: ConfigurationExport?
    public var supportBundle: SupportBundle?
    public var configurationValidation: ConfigurationValidationReport?
    public var sshConfigAudit: SSHConfigAuditReport?

    public init(
        ok: Bool,
        message: String,
        status: AppStatusSnapshot? = nil,
        sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus]? = nil,
        diagnostics: DiagnosticsSnapshot? = nil,
        configurationExport: ConfigurationExport? = nil,
        supportBundle: SupportBundle? = nil,
        configurationValidation: ConfigurationValidationReport? = nil,
        sshConfigAudit: SSHConfigAuditReport? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.sshAuto2FAServiceStatuses = sshAuto2FAServiceStatuses
        self.diagnostics = diagnostics
        self.configurationExport = configurationExport
        self.supportBundle = supportBundle
        self.configurationValidation = configurationValidation
        self.sshConfigAudit = sshConfigAudit
    }
}
