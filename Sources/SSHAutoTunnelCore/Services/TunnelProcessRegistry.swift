import Foundation

struct TunnelProcessRecord: Codable, Equatable, Sendable {
    var profileID: UUID
    var profileName: String
    var configuredSocksPort: Int
    var effectiveSocksPort: Int
    var pid: Int32
    var executable: String
    var arguments: [String]
    var startedAt: Date

    init(
        profileID: UUID,
        profileName: String,
        configuredSocksPort: Int,
        effectiveSocksPort: Int,
        pid: Int32,
        command: SSHCommand,
        startedAt: Date
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.configuredSocksPort = configuredSocksPort
        self.effectiveSocksPort = effectiveSocksPort
        self.pid = pid
        executable = command.executable
        arguments = command.arguments
        self.startedAt = startedAt
    }
}

protocol TunnelProcessRecording {
    func records() -> [TunnelProcessRecord]
    func records(for profileID: UUID) -> [TunnelProcessRecord]
    func upsert(_ record: TunnelProcessRecord)
    func remove(profileID: UUID, pid: Int32)
    func pruneInactive()
}

final class TunnelProcessRegistry: TunnelProcessRecording {
    private let urlProvider: () throws -> URL
    private let fileManager: FileManager
    private let processIsRunning: (Int32) -> Bool
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        self.init(urlProvider: AppPaths.tunnelProcessRegistryURL)
    }

    init(
        urlProvider: @escaping () throws -> URL,
        fileManager: FileManager = .default,
        processIsRunning: @escaping (Int32) -> Bool = InteractiveSSHSessionRegistry.defaultProcessIsRunning
    ) {
        self.urlProvider = urlProvider
        self.fileManager = fileManager
        self.processIsRunning = processIsRunning
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func records() -> [TunnelProcessRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readRecordsLocked()
    }

    func records(for profileID: UUID) -> [TunnelProcessRecord] {
        records().filter { $0.profileID == profileID }
    }

    func upsert(_ record: TunnelProcessRecord) {
        lock.lock()
        defer { lock.unlock() }
        var records = readRecordsLocked()
        records.removeAll { $0.profileID == record.profileID && $0.pid == record.pid }
        records.append(record)
        writeRecordsLocked(records)
    }

    func remove(profileID: UUID, pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        var records = readRecordsLocked()
        records.removeAll { $0.profileID == profileID && $0.pid == pid }
        writeRecordsLocked(records)
    }

    func pruneInactive() {
        lock.lock()
        defer { lock.unlock() }
        let activeRecords = readRecordsLocked().filter { processIsRunning($0.pid) }
        writeRecordsLocked(activeRecords)
    }

    private func readRecordsLocked() -> [TunnelProcessRecord] {
        guard let url = try? urlProvider(),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? decoder.decode([TunnelProcessRecord].self, from: data)) ?? []
    }

    private func writeRecordsLocked(_ records: [TunnelProcessRecord]) {
        guard let url = try? urlProvider() else { return }
        guard !records.isEmpty else {
            try? fileManager.removeItem(at: url)
            return
        }
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileProtection.protectFile(url)
    }
}

struct NoopTunnelProcessRegistry: TunnelProcessRecording {
    func records() -> [TunnelProcessRecord] { [] }
    func records(for profileID: UUID) -> [TunnelProcessRecord] { [] }
    func upsert(_ record: TunnelProcessRecord) {}
    func remove(profileID: UUID, pid: Int32) {}
    func pruneInactive() {}
}
