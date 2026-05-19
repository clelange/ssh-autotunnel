import Foundation

public enum TunnelAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case password
    case totp
    case passwordAndTOTP
    case kerberosAndTOTP

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "SSH config / key"
        case .password: "Password"
        case .totp: "TOTP"
        case .passwordAndTOTP: "Password + TOTP"
        case .kerberosAndTOTP: "Kerberos + TOTP"
        }
    }
}

public enum SSHHostKeyPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case acceptNew
    case strict
    case promptAndAccept

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .acceptNew: "Accept new, reject changed"
        case .strict: "Strict known hosts only"
        case .promptAndAccept: "Prompt and auto-accept"
        }
    }

    public var strictHostKeyCheckingValue: String? {
        switch self {
        case .acceptNew:
            "accept-new"
        case .strict:
            "yes"
        case .promptAndAccept:
            nil
        }
    }
}

public enum TunnelHealth: String, Codable, CaseIterable, Sendable {
    case stopped
    case connecting
    case healthy
    case degraded
    case unhealthy
    case reconnecting
    case failed

    public var isUsableForPAC: Bool {
        self == .healthy || self == .degraded
    }
}

public struct KeychainReference: Codable, Equatable, Sendable {
    public var account: String
    public var passwordService: String?
    public var totpService: String?

    public init(account: String = NSUserName(), passwordService: String? = nil, totpService: String? = nil) {
        self.account = account
        self.passwordService = passwordService
        self.totpService = totpService
    }
}

public struct HealthProbe: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var timeoutSeconds: TimeInterval

    public init(host: String = "example.com", port: Int = 80, timeoutSeconds: TimeInterval = 4) {
        self.host = host
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct TunnelProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var user: String?
    public var sshPort: Int
    public var localSocksPort: Int
    public var jumpHost: String?
    public var authMode: TunnelAuthMode
    public var hostKeyPolicy: SSHHostKeyPolicy
    public var keychain: KeychainReference
    public var autoReconnect: Bool
    public var healthProbe: HealthProbe?
    public var extraSSHOptions: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case user
        case sshPort
        case localSocksPort
        case jumpHost
        case authMode
        case hostKeyPolicy
        case keychain
        case autoReconnect
        case healthProbe
        case extraSSHOptions
    }

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String? = nil,
        sshPort: Int = 22,
        localSocksPort: Int,
        jumpHost: String? = nil,
        authMode: TunnelAuthMode = .none,
        hostKeyPolicy: SSHHostKeyPolicy = .acceptNew,
        keychain: KeychainReference = KeychainReference(),
        autoReconnect: Bool = true,
        healthProbe: HealthProbe? = nil,
        extraSSHOptions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.localSocksPort = localSocksPort
        self.jumpHost = jumpHost
        self.authMode = authMode
        self.hostKeyPolicy = hostKeyPolicy
        self.keychain = keychain
        self.autoReconnect = autoReconnect
        self.healthProbe = healthProbe
        self.extraSSHOptions = extraSSHOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        localSocksPort = try container.decode(Int.self, forKey: .localSocksPort)
        jumpHost = try container.decodeIfPresent(String.self, forKey: .jumpHost)
        authMode = try container.decodeIfPresent(TunnelAuthMode.self, forKey: .authMode) ?? .none
        hostKeyPolicy = try container.decodeIfPresent(SSHHostKeyPolicy.self, forKey: .hostKeyPolicy) ?? .acceptNew
        keychain = try container.decodeIfPresent(KeychainReference.self, forKey: .keychain) ?? KeychainReference()
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        healthProbe = try container.decodeIfPresent(HealthProbe.self, forKey: .healthProbe)
        extraSSHOptions = try container.decodeIfPresent([String].self, forKey: .extraSSHOptions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encode(sshPort, forKey: .sshPort)
        try container.encode(localSocksPort, forKey: .localSocksPort)
        try container.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try container.encode(authMode, forKey: .authMode)
        try container.encode(hostKeyPolicy, forKey: .hostKeyPolicy)
        try container.encode(keychain, forKey: .keychain)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encodeIfPresent(healthProbe, forKey: .healthProbe)
        try container.encode(extraSSHOptions, forKey: .extraSSHOptions)
    }

    public var sshDestination: String {
        if let user, !user.isEmpty {
            return "\(user)@\(host)"
        }
        return host
    }
}

public struct TunnelRuntimeStatus: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var health: TunnelHealth
    public var message: String
    public var pid: Int32?
    public var lastChanged: Date

    public init(profileID: UUID, health: TunnelHealth = .stopped, message: String = "Stopped", pid: Int32? = nil, lastChanged: Date = Date()) {
        self.profileID = profileID
        self.health = health
        self.message = message
        self.pid = pid
        self.lastChanged = lastChanged
    }
}

public enum PACFailureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case failClosed
    case directFallback

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .failClosed: "Fail closed"
        case .directFallback: "Direct fallback"
        }
    }
}

public struct PACRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var domainPattern: String
    public var profileID: UUID
    public var enabled: Bool
    public var failureMode: PACFailureMode

    public init(
        id: UUID = UUID(),
        name: String,
        domainPattern: String,
        profileID: UUID,
        enabled: Bool = true,
        failureMode: PACFailureMode = .failClosed
    ) {
        self.id = id
        self.name = name
        self.domainPattern = domainPattern
        self.profileID = profileID
        self.enabled = enabled
        self.failureMode = failureMode
    }
}

public enum ProxyApplyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case activeNetworkServicePAC

    public var id: String { rawValue }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var profiles: [TunnelProfile]
    public var pacRules: [PACRule]
    public var networkRules: [NetworkPolicyRule]
    public var pacHTTPPort: Int
    public var blockingHTTPProxyPort: Int
    public var apiHTTPPort: Int
    public var apiToken: String
    public var proxyApplyMode: ProxyApplyMode

    private enum CodingKeys: String, CodingKey {
        case profiles
        case pacRules
        case networkRules
        case pacHTTPPort
        case blockingHTTPProxyPort
        case apiHTTPPort
        case apiToken
        case proxyApplyMode
    }

    public init(
        profiles: [TunnelProfile] = [],
        pacRules: [PACRule] = [],
        networkRules: [NetworkPolicyRule] = [],
        pacHTTPPort: Int = 18483,
        blockingHTTPProxyPort: Int = 18485,
        apiHTTPPort: Int = 18484,
        apiToken: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        proxyApplyMode: ProxyApplyMode = .manual
    ) {
        self.profiles = profiles
        self.pacRules = pacRules
        self.networkRules = networkRules
        self.pacHTTPPort = pacHTTPPort
        self.blockingHTTPProxyPort = blockingHTTPProxyPort
        self.apiHTTPPort = apiHTTPPort
        self.apiToken = apiToken
        self.proxyApplyMode = proxyApplyMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([TunnelProfile].self, forKey: .profiles) ?? []
        pacRules = try container.decodeIfPresent([PACRule].self, forKey: .pacRules) ?? []
        networkRules = try container.decodeIfPresent([NetworkPolicyRule].self, forKey: .networkRules) ?? []
        pacHTTPPort = try container.decodeIfPresent(Int.self, forKey: .pacHTTPPort) ?? 18483
        blockingHTTPProxyPort = try container.decodeIfPresent(Int.self, forKey: .blockingHTTPProxyPort) ?? 18485
        apiHTTPPort = try container.decodeIfPresent(Int.self, forKey: .apiHTTPPort) ?? 18484
        apiToken = try container.decodeIfPresent(String.self, forKey: .apiToken) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        proxyApplyMode = try container.decodeIfPresent(ProxyApplyMode.self, forKey: .proxyApplyMode) ?? .manual
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(pacRules, forKey: .pacRules)
        try container.encode(networkRules, forKey: .networkRules)
        try container.encode(pacHTTPPort, forKey: .pacHTTPPort)
        try container.encode(blockingHTTPProxyPort, forKey: .blockingHTTPProxyPort)
        try container.encode(apiHTTPPort, forKey: .apiHTTPPort)
        try container.encode(apiToken, forKey: .apiToken)
        try container.encode(proxyApplyMode, forKey: .proxyApplyMode)
    }

    public static func defaultConfiguration() -> AppConfiguration {
        let lxplus = TunnelProfile(
            name: "CERN lxplus",
            host: "lxplus.cern.ch",
            localSocksPort: 1081,
            authMode: .kerberosAndTOTP,
            keychain: KeychainReference(account: NSUserName(), totpService: SSHAuto2FAPresets.cernLxplusTOTPService),
            healthProbe: HealthProbe(host: "lxplus.cern.ch", port: 22)
        )

        let tier3 = TunnelProfile(
            name: "PSI Tier-3",
            host: "t3ui07.psi.ch",
            localSocksPort: 1082,
            jumpHost: "t3hop01.psi.ch",
            authMode: .passwordAndTOTP,
            keychain: KeychainReference(
                account: NSUserName(),
                passwordService: SSHAuto2FAPresets.psiTier3PasswordService,
                totpService: SSHAuto2FAPresets.psiTier3TOTPService
            ),
            healthProbe: HealthProbe(host: "t3ui07.psi.ch", port: 22)
        )

        return AppConfiguration(
            profiles: [lxplus, tier3],
            pacRules: [
                PACRule(name: "CERN", domainPattern: "*.cern.ch", profileID: lxplus.id),
                PACRule(name: "PSI Tier-3", domainPattern: "*.psi.ch", profileID: tier3.id)
            ],
            networkRules: [
                NetworkPolicyRule(name: "CERN trusted network", match: .init(searchDomainContains: "cern.ch"), action: .disableProxy)
            ],
            proxyApplyMode: .manual
        )
    }
}
