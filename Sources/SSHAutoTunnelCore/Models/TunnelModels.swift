import Foundation

public enum TunnelAuthMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
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

public enum SSHHostKeyPolicy: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
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
    case stopping
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

public struct KeychainReference: Codable, Equatable, Hashable, Sendable {
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

public struct SSHLaunchOptions: Equatable, Sendable {
    public static let standard = SSHLaunchOptions()

    public var verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }
}

public enum ProfileNotificationPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case failuresAndRecoveries
    case allStatusChanges

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .failuresAndRecoveries: "Failures and recoveries"
        case .allStatusChanges: "All status changes"
        }
    }
}

public enum SSHLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case info
    case debug1
    case debug2
    case debug3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .info: "INFO"
        case .debug1: "DEBUG1"
        case .debug2: "DEBUG2"
        case .debug3: "DEBUG3"
        }
    }

    public var sshValue: String {
        switch self {
        case .info: "INFO"
        case .debug1: "DEBUG1"
        case .debug2: "DEBUG2"
        case .debug3: "DEBUG3"
        }
    }
}

public enum SSHAddressFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case ipv4
    case ipv6

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .any: "Any"
        case .ipv4: "IPv4"
        case .ipv6: "IPv6"
        }
    }

    public var sshValue: String {
        switch self {
        case .any: "any"
        case .ipv4: "inet"
        case .ipv6: "inet6"
        }
    }
}

public enum SSHOptionToggle: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemDefault
    case enabled
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .systemDefault: "Default"
        case .enabled: "Yes"
        case .disabled: "No"
        }
    }

    public var sshYesNoValue: String? {
        switch self {
        case .systemDefault: nil
        case .enabled: "yes"
        case .disabled: "no"
        }
    }
}

public struct LocalPortForward: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var bindAddress: String?
    public var localPort: Int
    public var targetHost: String
    public var targetPort: Int

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        bindAddress: String? = "127.0.0.1",
        localPort: Int,
        targetHost: String,
        targetPort: Int
    ) {
        self.id = id
        self.enabled = enabled
        self.bindAddress = bindAddress
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public var sshArgument: String {
        let bind = bindAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = bind.isEmpty ? "\(localPort)" : "\(bind):\(localPort)"
        return "\(source):\(targetHost):\(targetPort)"
    }
}

public struct CuratedSSHOptions: Codable, Equatable, Sendable {
    public var bindAddress: String?
    public var addressFamily: SSHAddressFamily
    public var compression: SSHOptionToggle
    public var identityFiles: [String]
    public var certificateFiles: [String]
    public var forwardAgent: SSHOptionToggle
    public var proxyCommand: String?
    public var maxReconnectAttempts: Int?

    private enum CodingKeys: String, CodingKey {
        case bindAddress
        case addressFamily
        case compression
        case identityFiles
        case certificateFiles
        case forwardAgent
        case proxyCommand
        case maxReconnectAttempts
    }

    public init(
        bindAddress: String? = nil,
        addressFamily: SSHAddressFamily = .any,
        compression: SSHOptionToggle = .systemDefault,
        identityFiles: [String] = [],
        certificateFiles: [String] = [],
        forwardAgent: SSHOptionToggle = .systemDefault,
        proxyCommand: String? = nil,
        maxReconnectAttempts: Int? = TunnelLifecyclePolicy.maximumReconnectAttempts
    ) {
        self.bindAddress = bindAddress
        self.addressFamily = addressFamily
        self.compression = compression
        self.identityFiles = identityFiles
        self.certificateFiles = certificateFiles
        self.forwardAgent = forwardAgent
        self.proxyCommand = proxyCommand
        self.maxReconnectAttempts = maxReconnectAttempts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bindAddress = try container.decodeIfPresent(String.self, forKey: .bindAddress)
        addressFamily = try container.decodeIfPresent(SSHAddressFamily.self, forKey: .addressFamily) ?? .any
        compression = try container.decodeIfPresent(SSHOptionToggle.self, forKey: .compression) ?? .systemDefault
        identityFiles = try container.decodeIfPresent([String].self, forKey: .identityFiles) ?? []
        certificateFiles = try container.decodeIfPresent([String].self, forKey: .certificateFiles) ?? []
        forwardAgent = try container.decodeIfPresent(SSHOptionToggle.self, forKey: .forwardAgent) ?? .systemDefault
        proxyCommand = try container.decodeIfPresent(String.self, forKey: .proxyCommand)
        maxReconnectAttempts = try container.decodeIfPresent(Int.self, forKey: .maxReconnectAttempts)
            ?? TunnelLifecyclePolicy.maximumReconnectAttempts
    }
}

public struct TunnelProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var user: String?
    public var sshPort: Int
    public var localSocksPort: Int
    public var interactiveHost: String?
    public var jumpHost: String?
    public var authMode: TunnelAuthMode
    public var hostKeyPolicy: SSHHostKeyPolicy
    public var keychain: KeychainReference
    public var autoReconnect: Bool
    public var healthProbe: HealthProbe?
    public var tags: [String]
    public var includeInConnectAll: Bool
    public var connectOnLaunch: Bool
    public var notificationPolicy: ProfileNotificationPolicy
    public var sshLogLevel: SSHLogLevel
    public var tunnelRequestsRemoteSession: Bool
    public var localPortForwardings: [LocalPortForward]
    public var curatedSSHOptions: CuratedSSHOptions
    public var extraSSHOptions: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case user
        case sshPort
        case localSocksPort
        case interactiveHost
        case jumpHost
        case authMode
        case hostKeyPolicy
        case keychain
        case autoReconnect
        case healthProbe
        case tags
        case includeInConnectAll
        case connectOnLaunch
        case notificationPolicy
        case sshLogLevel
        case tunnelRequestsRemoteSession
        case localPortForwardings
        case curatedSSHOptions
        case extraSSHOptions
    }

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String? = nil,
        sshPort: Int = 22,
        localSocksPort: Int,
        interactiveHost: String? = nil,
        jumpHost: String? = nil,
        authMode: TunnelAuthMode = .none,
        hostKeyPolicy: SSHHostKeyPolicy = .acceptNew,
        keychain: KeychainReference = KeychainReference(),
        autoReconnect: Bool = true,
        healthProbe: HealthProbe? = nil,
        tags: [String] = [],
        includeInConnectAll: Bool = true,
        connectOnLaunch: Bool = false,
        notificationPolicy: ProfileNotificationPolicy = .failuresAndRecoveries,
        sshLogLevel: SSHLogLevel = .info,
        tunnelRequestsRemoteSession: Bool = false,
        localPortForwardings: [LocalPortForward] = [],
        curatedSSHOptions: CuratedSSHOptions = CuratedSSHOptions(),
        extraSSHOptions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.localSocksPort = localSocksPort
        self.interactiveHost = interactiveHost
        self.jumpHost = jumpHost
        self.authMode = authMode
        self.hostKeyPolicy = hostKeyPolicy
        self.keychain = keychain
        self.autoReconnect = autoReconnect
        self.healthProbe = healthProbe
        self.tags = tags
        self.includeInConnectAll = includeInConnectAll
        self.connectOnLaunch = connectOnLaunch
        self.notificationPolicy = notificationPolicy
        self.sshLogLevel = sshLogLevel
        self.tunnelRequestsRemoteSession = tunnelRequestsRemoteSession
        self.localPortForwardings = localPortForwardings
        self.curatedSSHOptions = curatedSSHOptions
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
        interactiveHost = try container.decodeIfPresent(String.self, forKey: .interactiveHost)
        jumpHost = try container.decodeIfPresent(String.self, forKey: .jumpHost)
        authMode = try container.decodeIfPresent(TunnelAuthMode.self, forKey: .authMode) ?? .none
        hostKeyPolicy = try container.decodeIfPresent(SSHHostKeyPolicy.self, forKey: .hostKeyPolicy) ?? .acceptNew
        keychain = try container.decodeIfPresent(KeychainReference.self, forKey: .keychain) ?? KeychainReference()
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        healthProbe = try container.decodeIfPresent(HealthProbe.self, forKey: .healthProbe)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        includeInConnectAll = try container.decodeIfPresent(Bool.self, forKey: .includeInConnectAll) ?? true
        connectOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? false
        notificationPolicy = try container.decodeIfPresent(ProfileNotificationPolicy.self, forKey: .notificationPolicy) ?? .failuresAndRecoveries
        sshLogLevel = try container.decodeIfPresent(SSHLogLevel.self, forKey: .sshLogLevel) ?? .info
        tunnelRequestsRemoteSession = try container.decodeIfPresent(Bool.self, forKey: .tunnelRequestsRemoteSession) ?? false
        localPortForwardings = try container.decodeIfPresent([LocalPortForward].self, forKey: .localPortForwardings) ?? []
        curatedSSHOptions = try container.decodeIfPresent(CuratedSSHOptions.self, forKey: .curatedSSHOptions) ?? CuratedSSHOptions()
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
        try container.encodeIfPresent(interactiveHost, forKey: .interactiveHost)
        try container.encodeIfPresent(jumpHost, forKey: .jumpHost)
        try container.encode(authMode, forKey: .authMode)
        try container.encode(hostKeyPolicy, forKey: .hostKeyPolicy)
        try container.encode(keychain, forKey: .keychain)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encodeIfPresent(healthProbe, forKey: .healthProbe)
        try container.encode(tags, forKey: .tags)
        try container.encode(includeInConnectAll, forKey: .includeInConnectAll)
        try container.encode(connectOnLaunch, forKey: .connectOnLaunch)
        try container.encode(notificationPolicy, forKey: .notificationPolicy)
        try container.encode(sshLogLevel, forKey: .sshLogLevel)
        try container.encode(tunnelRequestsRemoteSession, forKey: .tunnelRequestsRemoteSession)
        try container.encode(localPortForwardings, forKey: .localPortForwardings)
        try container.encode(curatedSSHOptions, forKey: .curatedSSHOptions)
        try container.encode(extraSSHOptions, forKey: .extraSSHOptions)
    }

    public var sshDestination: String {
        if let user, !user.isEmpty {
            return "\(user)@\(host)"
        }
        return host
    }

    public var resolvedInteractiveHost: String {
        let candidate = interactiveHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? host : candidate
    }
}

public struct TunnelRuntimeStatus: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var health: TunnelHealth
    public var message: String
    public var pid: Int32?
    public var effectiveLocalSocksPort: Int?
    public var lastChanged: Date

    public init(
        profileID: UUID,
        health: TunnelHealth = .stopped,
        message: String = "Stopped",
        pid: Int32? = nil,
        effectiveLocalSocksPort: Int? = nil,
        lastChanged: Date = Date()
    ) {
        self.profileID = profileID
        self.health = health
        self.message = message
        self.pid = pid
        self.effectiveLocalSocksPort = effectiveLocalSocksPort
        self.lastChanged = lastChanged
    }
}

public struct HopRuntimeStatus: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var jumpHost: String
    public var health: TunnelHealth
    public var message: String
    public var pid: Int32?
    public var ownership: HopMasterOwnership?
    public var issue: HopConnectionIssue?
    public var lastChanged: Date

    public init(
        profileID: UUID,
        jumpHost: String,
        health: TunnelHealth = .stopped,
        message: String = "Stopped",
        pid: Int32? = nil,
        ownership: HopMasterOwnership? = nil,
        issue: HopConnectionIssue? = nil,
        lastChanged: Date = Date()
    ) {
        self.profileID = profileID
        self.jumpHost = jumpHost
        self.health = health
        self.message = message
        self.pid = pid
        self.ownership = ownership
        self.issue = issue
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
        failureMode: PACFailureMode = .directFallback
    ) {
        self.id = id
        self.name = name
        self.domainPattern = domainPattern
        self.profileID = profileID
        self.enabled = enabled
        self.failureMode = failureMode
    }
}

public enum PACAppendSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case url
    case file

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .url: "URL"
        case .file: "Local file"
        }
    }
}

public struct PACAppendSource: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var kind: PACAppendSourceKind
    public var location: String

    public init(
        enabled: Bool = false,
        kind: PACAppendSourceKind = .url,
        location: String = ""
    ) {
        self.enabled = enabled
        self.kind = kind
        self.location = location
    }

    public var trimmedLocation: String {
        location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isReadyToLoad: Bool {
        enabled && !trimmedLocation.isEmpty
    }
}

public enum ProxyApplyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case activeNetworkServicePAC

    public var id: String { rawValue }
}

public enum InteractiveTerminalApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case terminal
    case iTerm2
    case ghostty
    case custom

    public var id: String { rawValue }

    public static var supportedLaunchAdapters: [InteractiveTerminalApp] {
        [.terminal, .iTerm2, .ghostty]
    }

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .custom: "Custom app"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm2: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .custom: nil
        }
    }
}

public struct InteractiveTerminalPreference: Codable, Equatable, Sendable {
    public var app: InteractiveTerminalApp
    public var customApplicationPath: String

    public init(
        app: InteractiveTerminalApp = .terminal,
        customApplicationPath: String = ""
    ) {
        self.app = app
        self.customApplicationPath = customApplicationPath
    }
}

public enum ConnectionTemplateID: String, Codable, CaseIterable, Identifiable, Sendable {
    case cernLxPlus
    case psiTier3
    case psiGeneral

    public var id: String { rawValue }
}

public struct ConnectionTemplateAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: ConnectionTemplateID
    public var displayName: String
    public var username: String
    public var credentialHost: String
    public var interactiveHost: String?
    public var tunnelEnabled: Bool
    public var tunnelHost: String?
    public var jumpHost: String?
    public var localSocksPort: Int?
    public var pacDomainPattern: String?
    public var keychain: KeychainReference

    public init(
        id: ConnectionTemplateID,
        displayName: String,
        username: String,
        credentialHost: String,
        interactiveHost: String? = nil,
        tunnelEnabled: Bool = false,
        tunnelHost: String? = nil,
        jumpHost: String? = nil,
        localSocksPort: Int? = nil,
        pacDomainPattern: String? = nil,
        keychain: KeychainReference = KeychainReference()
    ) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.credentialHost = credentialHost
        self.interactiveHost = interactiveHost
        self.tunnelEnabled = tunnelEnabled
        self.tunnelHost = tunnelHost
        self.jumpHost = jumpHost
        self.localSocksPort = localSocksPort
        self.pacDomainPattern = pacDomainPattern
        self.keychain = keychain
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var templateAccounts: [ConnectionTemplateAccount]
    public var profiles: [TunnelProfile]
    public var pacRules: [PACRule]
    public var networkRules: [NetworkPolicyRule]
    public var pacHTTPPort: Int
    public var blockingHTTPProxyPort: Int
    public var apiHTTPPort: Int
    public var apiToken: String
    public var proxyApplyMode: ProxyApplyMode
    public var pacAppendSource: PACAppendSource
    public var interactiveTerminal: InteractiveTerminalPreference

    private enum CodingKeys: String, CodingKey {
        case templateAccounts
        case profiles
        case pacRules
        case networkRules
        case pacHTTPPort
        case blockingHTTPProxyPort
        case apiHTTPPort
        case apiToken
        case proxyApplyMode
        case pacAppendSource
        case interactiveTerminal
    }

    public init(
        templateAccounts: [ConnectionTemplateAccount] = [],
        profiles: [TunnelProfile] = [],
        pacRules: [PACRule] = [],
        networkRules: [NetworkPolicyRule] = [],
        pacHTTPPort: Int = 18483,
        blockingHTTPProxyPort: Int = 18485,
        apiHTTPPort: Int = 18484,
        apiToken: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        proxyApplyMode: ProxyApplyMode = .manual,
        pacAppendSource: PACAppendSource = PACAppendSource(),
        interactiveTerminal: InteractiveTerminalPreference = InteractiveTerminalPreference()
    ) {
        self.templateAccounts = templateAccounts
        self.profiles = profiles
        self.pacRules = pacRules
        self.networkRules = networkRules
        self.pacHTTPPort = pacHTTPPort
        self.blockingHTTPProxyPort = blockingHTTPProxyPort
        self.apiHTTPPort = apiHTTPPort
        self.apiToken = apiToken
        self.proxyApplyMode = proxyApplyMode
        self.pacAppendSource = pacAppendSource
        self.interactiveTerminal = interactiveTerminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        templateAccounts = try container.decodeIfPresent([ConnectionTemplateAccount].self, forKey: .templateAccounts) ?? []
        profiles = try container.decodeIfPresent([TunnelProfile].self, forKey: .profiles) ?? []
        pacRules = try container.decodeIfPresent([PACRule].self, forKey: .pacRules) ?? []
        networkRules = try container.decodeIfPresent([NetworkPolicyRule].self, forKey: .networkRules) ?? []
        pacHTTPPort = try container.decodeIfPresent(Int.self, forKey: .pacHTTPPort) ?? 18483
        blockingHTTPProxyPort = try container.decodeIfPresent(Int.self, forKey: .blockingHTTPProxyPort) ?? 18485
        apiHTTPPort = try container.decodeIfPresent(Int.self, forKey: .apiHTTPPort) ?? 18484
        apiToken = try container.decodeIfPresent(String.self, forKey: .apiToken) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        proxyApplyMode = try container.decodeIfPresent(ProxyApplyMode.self, forKey: .proxyApplyMode) ?? .manual
        pacAppendSource = try container.decodeIfPresent(PACAppendSource.self, forKey: .pacAppendSource) ?? PACAppendSource()
        interactiveTerminal = try container.decodeIfPresent(InteractiveTerminalPreference.self, forKey: .interactiveTerminal) ?? InteractiveTerminalPreference()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(templateAccounts, forKey: .templateAccounts)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(pacRules, forKey: .pacRules)
        try container.encode(networkRules, forKey: .networkRules)
        try container.encode(pacHTTPPort, forKey: .pacHTTPPort)
        try container.encode(blockingHTTPProxyPort, forKey: .blockingHTTPProxyPort)
        try container.encode(apiHTTPPort, forKey: .apiHTTPPort)
        try container.encode(apiToken, forKey: .apiToken)
        try container.encode(proxyApplyMode, forKey: .proxyApplyMode)
        try container.encode(pacAppendSource, forKey: .pacAppendSource)
        try container.encode(interactiveTerminal, forKey: .interactiveTerminal)
    }

    public static func defaultConfiguration() -> AppConfiguration {
        AppConfiguration(proxyApplyMode: .manual)
    }
}
