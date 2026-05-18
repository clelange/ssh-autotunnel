import Foundation

public final class ProxySnapshotStore {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL? = nil) throws {
        self.url = try url ?? AppPaths.proxySnapshotURL()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func save(_ snapshot: ProxySnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileProtection.protectDirectory(directory)
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
        try FileProtection.protectFile(url)
    }

    public func load() throws -> ProxySnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try FileProtection.protectDirectory(url.deletingLastPathComponent())
        try FileProtection.protectFile(url)
        let data = try Data(contentsOf: url)
        return try decoder.decode(ProxySnapshot.self, from: data)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
