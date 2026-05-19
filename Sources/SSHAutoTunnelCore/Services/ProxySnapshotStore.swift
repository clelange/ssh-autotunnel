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
        var snapshots = try loadAll()
        snapshots.removeAll { $0.serviceName == snapshot.serviceName }
        snapshots.append(snapshot)
        try saveAll(snapshots)
    }

    public func saveAll(_ snapshots: [ProxySnapshot]) throws {
        if snapshots.isEmpty {
            try clear()
            return
        }
        let directory = url.deletingLastPathComponent()
        try FileProtection.protectDirectory(directory)
        let archive = ProxySnapshotArchive(snapshots: snapshots.sorted { $0.serviceName < $1.serviceName })
        let data = try encoder.encode(archive)
        try data.write(to: url, options: [.atomic])
        try FileProtection.protectFile(url)
    }

    public func load() throws -> ProxySnapshot? {
        try loadAll().first
    }

    public func loadAll() throws -> [ProxySnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try FileProtection.protectDirectory(url.deletingLastPathComponent())
        try FileProtection.protectFile(url)
        let data = try Data(contentsOf: url)
        if let archive = try? decoder.decode(ProxySnapshotArchive.self, from: data) {
            return archive.snapshots
        }
        if let legacySnapshot = try? decoder.decode(ProxySnapshot.self, from: data) {
            return [legacySnapshot]
        }
        return try decoder.decode(ProxySnapshotArchive.self, from: data).snapshots
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private struct ProxySnapshotArchive: Codable {
    var snapshots: [ProxySnapshot]
}
