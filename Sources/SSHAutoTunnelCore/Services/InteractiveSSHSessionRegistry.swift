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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init() {
        self.init(directoryProvider: AppPaths.interactiveSessionDirectory)
    }

    public init(
        directoryProvider: @escaping () throws -> URL,
        fileManager: FileManager = .default
    ) {
        self.directoryProvider = directoryProvider
        self.fileManager = fileManager
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
                return try? decoder.decode(ActiveInteractiveSSHSession.self, from: data)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func markerURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
