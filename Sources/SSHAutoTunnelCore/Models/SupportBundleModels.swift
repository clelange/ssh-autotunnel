import Foundation

public struct ConfigurationExportRedaction: Codable, Equatable, Sendable {
    public var omittedFields: [String]
    public var note: String

    public init(
        omittedFields: [String] = ["apiToken"],
        note: String = "Local API tokens and Keychain secret values are not included."
    ) {
        self.omittedFields = omittedFields
        self.note = note
    }
}

public struct ConfigurationExport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var appIdentifier: String
    public var accounts: [AccountConfiguration]
    public var profiles: [TunnelProfile]
    public var pacRules: [PACRule]
    public var networkRules: [NetworkPolicyRule]
    public var pacHTTPPort: Int
    public var blockingHTTPProxyPort: Int
    public var apiHTTPPort: Int
    public var proxyApplyMode: ProxyApplyMode
    public var pacAppendSource: PACAppendSource
    public var redaction: ConfigurationExportRedaction

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportedAt
        case appIdentifier
        case accounts
        case profiles
        case pacRules
        case networkRules
        case pacHTTPPort
        case blockingHTTPProxyPort
        case apiHTTPPort
        case proxyApplyMode
        case pacAppendSource
        case redaction
    }

    public init(
        schemaVersion: Int = 2,
        exportedAt: Date = Date(),
        appIdentifier: String,
        accounts: [AccountConfiguration] = [],
        profiles: [TunnelProfile],
        pacRules: [PACRule],
        networkRules: [NetworkPolicyRule],
        pacHTTPPort: Int,
        blockingHTTPProxyPort: Int,
        apiHTTPPort: Int,
        proxyApplyMode: ProxyApplyMode,
        pacAppendSource: PACAppendSource = PACAppendSource(),
        redaction: ConfigurationExportRedaction = ConfigurationExportRedaction()
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appIdentifier = appIdentifier
        self.accounts = accounts
        self.profiles = profiles
        self.pacRules = pacRules
        self.networkRules = networkRules
        self.pacHTTPPort = pacHTTPPort
        self.blockingHTTPProxyPort = blockingHTTPProxyPort
        self.apiHTTPPort = apiHTTPPort
        self.proxyApplyMode = proxyApplyMode
        self.pacAppendSource = pacAppendSource
        self.redaction = redaction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appIdentifier = try container.decode(String.self, forKey: .appIdentifier)
        accounts = try container.decodeIfPresent([AccountConfiguration].self, forKey: .accounts) ?? []
        profiles = try container.decode([TunnelProfile].self, forKey: .profiles)
        pacRules = try container.decode([PACRule].self, forKey: .pacRules)
        networkRules = try container.decode([NetworkPolicyRule].self, forKey: .networkRules)
        pacHTTPPort = try container.decode(Int.self, forKey: .pacHTTPPort)
        blockingHTTPProxyPort = try container.decode(Int.self, forKey: .blockingHTTPProxyPort)
        apiHTTPPort = try container.decode(Int.self, forKey: .apiHTTPPort)
        proxyApplyMode = try container.decode(ProxyApplyMode.self, forKey: .proxyApplyMode)
        pacAppendSource = try container.decodeIfPresent(PACAppendSource.self, forKey: .pacAppendSource) ?? PACAppendSource()
        redaction = try container.decodeIfPresent(ConfigurationExportRedaction.self, forKey: .redaction) ?? ConfigurationExportRedaction()
    }
}

public struct SupportBundle: Codable, Equatable, Sendable {
    public var bundleVersion: Int
    public var generatedAt: Date
    public var appIdentifier: String
    public var configuration: ConfigurationExport
    public var diagnostics: DiagnosticsSnapshot?

    public init(
        bundleVersion: Int = 1,
        generatedAt: Date = Date(),
        appIdentifier: String,
        configuration: ConfigurationExport,
        diagnostics: DiagnosticsSnapshot?
    ) {
        self.bundleVersion = bundleVersion
        self.generatedAt = generatedAt
        self.appIdentifier = appIdentifier
        self.configuration = configuration
        self.diagnostics = diagnostics
    }
}

public struct ConfigurationValidationReport: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var messages: [String]
    public var profileCount: Int
    public var pacRuleCount: Int
    public var networkRuleCount: Int

    public init(
        ok: Bool,
        message: String,
        messages: [String] = [],
        profileCount: Int,
        pacRuleCount: Int,
        networkRuleCount: Int
    ) {
        self.ok = ok
        self.message = message
        self.messages = messages
        self.profileCount = profileCount
        self.pacRuleCount = pacRuleCount
        self.networkRuleCount = networkRuleCount
    }
}
