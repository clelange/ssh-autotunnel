import Darwin
import Foundation

public struct ActiveInteractiveSSHSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var profileName: String
    public var jumpHost: String
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        profileName: String,
        jumpHost: String,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.jumpHost = jumpHost
        self.startedAt = startedAt
    }
}

public final class InteractiveSSHSessionRegistry {
    private let directoryProvider: () throws -> URL
    private let fileManager: FileManager
    private let processIsRunning: (Int32) -> Bool
    private let pidWriteGraceInterval: TimeInterval
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init() {
        self.init(directoryProvider: AppPaths.interactiveSessionDirectory)
    }

    public init(
        directoryProvider: @escaping () throws -> URL,
        fileManager: FileManager = .default,
        processIsRunning: @escaping (Int32) -> Bool = InteractiveSSHSessionRegistry.defaultProcessIsRunning,
        pidWriteGraceInterval: TimeInterval = 15,
        now: @escaping () -> Date = Date.init
    ) {
        self.directoryProvider = directoryProvider
        self.fileManager = fileManager
        self.processIsRunning = processIsRunning
        self.pidWriteGraceInterval = pidWriteGraceInterval
        self.now = now
    }

    @discardableResult
    public func createMarker(for session: ActiveInteractiveSSHSession) throws -> URL {
        let directory = try directoryProvider()
        let url = markerURL(for: session.id, in: directory)
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
        try FileProtection.protectFile(url)
        return url
    }

    public func removeMarker(at url: URL) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: pidURL(forMarkerURL: url))
    }

    public func activeSessions() -> [ActiveInteractiveSSHSession] {
        guard let directory = try? directoryProvider(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let session = try? decoder.decode(ActiveInteractiveSSHSession.self, from: data) else {
                    return nil
                }
                guard isMarkerActive(at: url) else {
                    removeMarker(at: url)
                    return nil
                }
                return session
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func markerURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func pidURL(forMarkerURL url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("pid")
    }

    private func isMarkerActive(at url: URL) -> Bool {
        let pidURL = pidURL(forMarkerURL: url)
        if let pid = readPID(at: pidURL) {
            return processIsRunning(pid)
        }

        guard let modificationDate = markerModificationDate(url) else {
            return false
        }
        return now().timeIntervalSince(modificationDate) <= pidWriteGraceInterval
    }

    private func readPID(at url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    private func markerModificationDate(_ url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    public static func defaultProcessIsRunning(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
