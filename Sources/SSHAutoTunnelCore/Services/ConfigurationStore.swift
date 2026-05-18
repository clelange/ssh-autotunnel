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
            let data = try Data(contentsOf: url)
            return try decoder.decode(AppConfiguration.self, from: data)
        }

        let config = AppConfiguration.defaultConfiguration()
        try save(config)
        return config
    }

    public func loadRecovering() throws -> ConfigurationLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let config = AppConfiguration.defaultConfiguration()
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: [.atomic])
    }

    private func backupInvalidConfiguration() throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = directory.appendingPathComponent("\(url.lastPathComponent).invalid-\(stamp)")

        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.moveItem(at: url, to: backupURL)
        return backupURL
    }
}
