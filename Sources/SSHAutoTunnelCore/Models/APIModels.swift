import Foundation

public enum ControlAction: String, Codable, Sendable {
    case connect
    case disconnect
    case reconnect
    case status
    case pacURL
    case reloadPAC
    case applySystemPAC
    case restoreSystemPAC
    case importSSHAuto2FA
    case checkSSHAuto2FA
    case importSSHConfig
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
    case supportBundle
}

public struct ControlRequest: Codable, Sendable {
    public var action: ControlAction
    public var profileName: String?
    public var profileID: UUID?
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
    public var localSocksPort: Int
    public var health: TunnelHealth
    public var message: String
    public var pid: Int32?

    public init(profile: TunnelProfile, status: TunnelRuntimeStatus) {
        id = profile.id
        name = profile.name
        localSocksPort = profile.localSocksPort
        health = status.health
        message = status.message
        pid = status.pid
    }
}

public struct AppStatusSnapshot: Codable, Equatable, Sendable {
    public var pacURL: String
    public var proxyDisabledByNetworkPolicy: Bool
    public var matchedNetworkRule: String?
    public var networkDisabledProfileIDs: [UUID]
    public var profiles: [ProfileStatusSnapshot]

    public init(
        pacURL: String,
        proxyDisabledByNetworkPolicy: Bool,
        matchedNetworkRule: String?,
        networkDisabledProfileIDs: [UUID] = [],
        profiles: [ProfileStatusSnapshot]
    ) {
        self.pacURL = pacURL
        self.proxyDisabledByNetworkPolicy = proxyDisabledByNetworkPolicy
        self.matchedNetworkRule = matchedNetworkRule
        self.networkDisabledProfileIDs = networkDisabledProfileIDs
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
    public var proxyDisabledByNetworkPolicy: Bool
    public var matchedNetworkRule: String?
    public var networkDisabledProfileIDs: [UUID]
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
        proxyDisabledByNetworkPolicy: Bool,
        matchedNetworkRule: String?,
        networkDisabledProfileIDs: [UUID] = [],
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
        self.proxyDisabledByNetworkPolicy = proxyDisabledByNetworkPolicy
        self.matchedNetworkRule = matchedNetworkRule
        self.networkDisabledProfileIDs = networkDisabledProfileIDs
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

    public init(
        ok: Bool,
        message: String,
        status: AppStatusSnapshot? = nil,
        sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus]? = nil,
        diagnostics: DiagnosticsSnapshot? = nil,
        configurationExport: ConfigurationExport? = nil,
        supportBundle: SupportBundle? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.sshAuto2FAServiceStatuses = sshAuto2FAServiceStatuses
        self.diagnostics = diagnostics
        self.configurationExport = configurationExport
        self.supportBundle = supportBundle
    }
}
