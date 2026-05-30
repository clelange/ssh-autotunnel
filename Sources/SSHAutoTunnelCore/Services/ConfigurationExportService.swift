import Foundation

public enum ConfigurationExportError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateProfileID(UUID)
    case duplicatePACRuleID(UUID)
    case duplicateNetworkRuleID(UUID)
    case missingPACRuleProfile(UUID)
    case missingNetworkRuleProfile(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported configuration export schema version \(version)."
        case .duplicateProfileID(let id):
            "Configuration export contains duplicate profile id \(id.uuidString)."
        case .duplicatePACRuleID(let id):
            "Configuration export contains duplicate PAC rule id \(id.uuidString)."
        case .duplicateNetworkRuleID(let id):
            "Configuration export contains duplicate network rule id \(id.uuidString)."
        case .missingPACRuleProfile(let id):
            "Configuration export PAC rule references missing profile \(id.uuidString)."
        case .missingNetworkRuleProfile(let id):
            "Configuration export network rule references missing profile \(id.uuidString)."
        }
    }
}

public enum ConfigurationExportService {
    public static let schemaVersion = 3
    public static let bundleVersion = 1

    public static func decodeExportDocument(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder(),
        exportedAt: Date = Date(),
        appIdentifier: String = AppPaths.appIdentifier
    ) throws -> ConfigurationExport {
        if let export = try? decoder.decode(ConfigurationExport.self, from: data) {
            return export
        }
        let configuration = try decoder.decode(AppConfiguration.self, from: data)
        return makeExport(
            from: configuration,
            exportedAt: exportedAt,
            appIdentifier: appIdentifier
        )
    }

    public static func makeExport(
        from configuration: AppConfiguration,
        exportedAt: Date = Date(),
        appIdentifier: String = AppPaths.appIdentifier
    ) -> ConfigurationExport {
        ConfigurationExport(
            schemaVersion: schemaVersion,
            exportedAt: exportedAt,
            appIdentifier: appIdentifier,
            accounts: configuration.accounts,
            profiles: configuration.profiles,
            pacRules: configuration.pacRules,
            networkRules: configuration.networkRules,
            pacHTTPPort: configuration.pacHTTPPort,
            blockingHTTPProxyPort: configuration.blockingHTTPProxyPort,
            apiHTTPPort: configuration.apiHTTPPort,
            proxyApplyMode: configuration.proxyApplyMode,
            pacAppendSource: configuration.pacAppendSource,
            interactiveTerminal: configuration.interactiveTerminal
        )
    }

    public static func importConfiguration(
        from export: ConfigurationExport,
        preservingLocalValuesFrom currentConfiguration: AppConfiguration
    ) throws -> AppConfiguration {
        try validate(export)
        let imported = AppConfiguration(
            accounts: export.accounts,
            profiles: export.profiles,
            pacRules: export.pacRules,
            networkRules: export.networkRules,
            pacHTTPPort: export.pacHTTPPort,
            blockingHTTPProxyPort: export.blockingHTTPProxyPort,
            apiHTTPPort: export.apiHTTPPort,
            apiToken: currentConfiguration.apiToken,
            proxyApplyMode: export.proxyApplyMode,
            pacAppendSource: export.pacAppendSource,
            interactiveTerminal: export.interactiveTerminal
        )
        try PortConfigurationValidator.validate(imported)
        return imported
    }

    public static func validationReport(
        for export: ConfigurationExport,
        preservingLocalValuesFrom currentConfiguration: AppConfiguration
    ) -> ConfigurationValidationReport {
        do {
            _ = try importConfiguration(from: export, preservingLocalValuesFrom: currentConfiguration)
            return ConfigurationValidationReport(
                ok: true,
                message: "Configuration export is valid",
                profileCount: export.profiles.count,
                pacRuleCount: export.pacRules.count,
                networkRuleCount: export.networkRules.count
            )
        } catch let error as PortConfigurationError {
            return ConfigurationValidationReport(
                ok: false,
                message: error.localizedDescription,
                messages: error.messages,
                profileCount: export.profiles.count,
                pacRuleCount: export.pacRules.count,
                networkRuleCount: export.networkRules.count
            )
        } catch {
            return ConfigurationValidationReport(
                ok: false,
                message: error.localizedDescription,
                messages: [error.localizedDescription],
                profileCount: export.profiles.count,
                pacRuleCount: export.pacRules.count,
                networkRuleCount: export.networkRules.count
            )
        }
    }

    public static func makeSupportBundle(
        configuration: AppConfiguration,
        diagnostics: DiagnosticsSnapshot?,
        generatedAt: Date = Date(),
        appIdentifier: String = AppPaths.appIdentifier,
        homeDirectoryPath: String? = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> SupportBundle {
        SupportBundle(
            bundleVersion: bundleVersion,
            generatedAt: generatedAt,
            appIdentifier: appIdentifier,
            configuration: makeExport(
                from: configuration,
                exportedAt: generatedAt,
                appIdentifier: appIdentifier
            ),
            diagnostics: redactedDiagnostics(diagnostics, homeDirectoryPath: homeDirectoryPath)
        )
    }

    public static func validate(_ export: ConfigurationExport) throws {
        guard (1...schemaVersion).contains(export.schemaVersion) else {
            throw ConfigurationExportError.unsupportedSchemaVersion(export.schemaVersion)
        }

        try validateUniqueIDs(export.profiles.map(\.id)) { ConfigurationExportError.duplicateProfileID($0) }
        try validateUniqueIDs(export.pacRules.map(\.id)) { ConfigurationExportError.duplicatePACRuleID($0) }
        try validateUniqueIDs(export.networkRules.map(\.id)) { ConfigurationExportError.duplicateNetworkRuleID($0) }

        let profileIDs = Set(export.profiles.map(\.id))
        for rule in export.pacRules where !profileIDs.contains(rule.profileID) {
            throw ConfigurationExportError.missingPACRuleProfile(rule.profileID)
        }
        for rule in export.networkRules {
            guard let profileID = rule.profileID else { continue }
            guard profileIDs.contains(profileID) else {
                throw ConfigurationExportError.missingNetworkRuleProfile(profileID)
            }
        }
    }

    private static func validateUniqueIDs(
        _ ids: [UUID],
        error: (UUID) -> ConfigurationExportError
    ) throws {
        var seen = Set<UUID>()
        for id in ids {
            if !seen.insert(id).inserted {
                throw error(id)
            }
        }
    }

    private static func redactedDiagnostics(
        _ diagnostics: DiagnosticsSnapshot?,
        homeDirectoryPath: String?
    ) -> DiagnosticsSnapshot? {
        guard var diagnostics else { return nil }
        diagnostics.fileStatuses = diagnostics.fileStatuses.map { status in
            var copy = status
            copy.path = redactedPath(status.path, homeDirectoryPath: homeDirectoryPath)
            return copy
        }
        return diagnostics
    }

    private static func redactedPath(_ path: String, homeDirectoryPath: String?) -> String {
        guard let homeDirectoryPath, !homeDirectoryPath.isEmpty, homeDirectoryPath != "/" else {
            return path
        }
        return path.replacingOccurrences(of: homeDirectoryPath, with: "~")
    }
}
