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
    public var profiles: [TunnelProfile]
    public var pacRules: [PACRule]
    public var networkRules: [NetworkPolicyRule]
    public var pacHTTPPort: Int
    public var blockingHTTPProxyPort: Int
    public var apiHTTPPort: Int
    public var proxyApplyMode: ProxyApplyMode
    public var redaction: ConfigurationExportRedaction

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date = Date(),
        appIdentifier: String,
        profiles: [TunnelProfile],
        pacRules: [PACRule],
        networkRules: [NetworkPolicyRule],
        pacHTTPPort: Int,
        blockingHTTPProxyPort: Int,
        apiHTTPPort: Int,
        proxyApplyMode: ProxyApplyMode,
        redaction: ConfigurationExportRedaction = ConfigurationExportRedaction()
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appIdentifier = appIdentifier
        self.profiles = profiles
        self.pacRules = pacRules
        self.networkRules = networkRules
        self.pacHTTPPort = pacHTTPPort
        self.blockingHTTPProxyPort = blockingHTTPProxyPort
        self.apiHTTPPort = apiHTTPPort
        self.proxyApplyMode = proxyApplyMode
        self.redaction = redaction
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
