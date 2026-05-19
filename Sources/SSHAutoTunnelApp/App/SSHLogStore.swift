import Foundation
import SSHAutoTunnelCore

struct SSHLogStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func logDirectoryURL() throws -> URL {
        let directory = try AppPaths.applicationSupportDirectory().appendingPathComponent("SSHLogs", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        return directory
    }

    func logURL(profileID: UUID) throws -> URL {
        try logDirectoryURL().appendingPathComponent("\(profileID.uuidString).log")
    }

    func readLog(profileID: UUID) throws -> String {
        let url = try logURL(profileID: profileID)
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func replaceLog(profileID: UUID, with text: String) throws {
        let url = try logURL(profileID: profileID)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileProtection.protectFile(url)
    }

    func append(_ text: String, profileID: UUID) throws {
        let url = try logURL(profileID: profileID)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
            try FileProtection.protectFile(url)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = text.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    func clearLog(profileID: UUID) throws {
        try replaceLog(profileID: profileID, with: "")
    }
}
