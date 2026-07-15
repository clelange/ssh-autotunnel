import Foundation

public struct ConfigurationLoadResult: Sendable {
    public var configuration: AppConfiguration
    public var recoveredFromError: String?
    public var backupURL: URL?

    public var didRecover: Bool {
        recoveredFromError != nil
    }

    public init(configuration: AppConfiguration, recoveredFromError: String? = nil, backupURL: URL? = nil) {
        self.configuration = configuration
        self.recoveredFromError = recoveredFromError
        self.backupURL = backupURL
    }
}

public final class ConfigurationStore {
    public static let defaultPreImportBackupRetentionCount = 10

    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL? = nil) throws {
        self.url = try url ?? AppPaths.configurationURL()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> AppConfiguration {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileProtection.protectDirectory(url.deletingLastPathComponent())
            try FileProtection.protectFile(url)
            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode(AppConfiguration.self, from: data)
            let reconnectMigration = ReconnectConfigurationMigration.migrate(decoded)
            let (migrated, didUpdateUsers) = SSHAuto2FAImporter.backfillPresetSSHUsers(in: reconnectMigration.configuration)
            if reconnectMigration.didUpdate || didUpdateUsers {
                try save(migrated)
            }
            return migrated
        }

        let (config, _) = SSHAuto2FAImporter.backfillPresetSSHUsers(in: AppConfiguration.defaultConfiguration())
        try save(config)
        return config
    }

    public func loadRecovering() throws -> ConfigurationLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let (config, _) = SSHAuto2FAImporter.backfillPresetSSHUsers(in: AppConfiguration.defaultConfiguration())
            try save(config)
            return ConfigurationLoadResult(configuration: config)
        }

        do {
            return ConfigurationLoadResult(configuration: try load())
        } catch {
            let backupURL = try backupInvalidConfiguration()
            let config = AppConfiguration.defaultConfiguration()
            try save(config)
            return ConfigurationLoadResult(
                configuration: config,
                recoveredFromError: error.localizedDescription,
                backupURL: backupURL
            )
        }
    }

    public func save(_ configuration: AppConfiguration) throws {
        let directory = url.deletingLastPathComponent()
        try FileProtection.protectDirectory(directory)
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: [.atomic])
        try FileProtection.protectFile(url)
    }

    public func backupCurrentConfiguration(label: String = "backup", retaining retainedBackupCount: Int? = nil) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let directory = url.deletingLastPathComponent()
        try FileProtection.protectDirectory(directory)
        try FileProtection.protectFile(url)

        let backupURL = stampedBackupURL(label: label)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.copyItem(at: url, to: backupURL)
        try FileProtection.protectFile(backupURL)
        if let retainedBackupCount {
            _ = try pruneBackups(label: label, keeping: retainedBackupCount)
        }
        return backupURL
    }

    @discardableResult
    public func pruneBackups(label: String, keeping retainedBackupCount: Int) throws -> [URL] {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let prefix = backupPrefix(label: label)
        let retainedBackupCount = max(0, retainedBackupCount)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(prefix) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard backups.count > retainedBackupCount else { return [] }

        let removedBackups = Array(backups.dropLast(retainedBackupCount))
        for backup in removedBackups {
            try FileManager.default.removeItem(at: backup)
        }
        return removedBackups
    }

    private func backupInvalidConfiguration() throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileProtection.protectDirectory(directory)

        let backupURL = stampedBackupURL(label: "invalid")

        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.moveItem(at: url, to: backupURL)
        try FileProtection.protectFile(backupURL)
        return backupURL
    }

    private func stampedBackupURL(label: String) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return url.deletingLastPathComponent().appendingPathComponent("\(backupPrefix(label: label))\(stamp)")
    }

    private func backupPrefix(label: String) -> String {
        let safeLabel = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let suffix = safeLabel.isEmpty ? "backup" : safeLabel
        return "\(url.lastPathComponent).\(suffix)-"
    }
}
