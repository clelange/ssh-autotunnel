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
}

public struct ControlRequest: Codable, Sendable {
    public var action: ControlAction
    public var profileName: String?
    public var profileID: UUID?

    public init(action: ControlAction, profileName: String? = nil, profileID: UUID? = nil) {
        self.action = action
        self.profileName = profileName
        self.profileID = profileID
    }
}

public struct ProfileStatusSnapshot: Codable, Sendable {
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

public struct AppStatusSnapshot: Codable, Sendable {
    public var pacURL: String
    public var proxyDisabledByNetworkPolicy: Bool
    public var matchedNetworkRule: String?
    public var profiles: [ProfileStatusSnapshot]

    public init(
        pacURL: String,
        proxyDisabledByNetworkPolicy: Bool,
        matchedNetworkRule: String?,
        profiles: [ProfileStatusSnapshot]
    ) {
        self.pacURL = pacURL
        self.proxyDisabledByNetworkPolicy = proxyDisabledByNetworkPolicy
        self.matchedNetworkRule = matchedNetworkRule
        self.profiles = profiles
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var status: AppStatusSnapshot?
    public var sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus]?

    public init(
        ok: Bool,
        message: String,
        status: AppStatusSnapshot? = nil,
        sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus]? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.sshAuto2FAServiceStatuses = sshAuto2FAServiceStatuses
    }
}
