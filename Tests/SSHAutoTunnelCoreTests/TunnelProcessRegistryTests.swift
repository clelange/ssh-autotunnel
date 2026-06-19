import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class TunnelProcessRegistryTests: XCTestCase {
    func testUpsertsListsAndRemovesRecords() throws {
        let url = try temporaryDirectory().appendingPathComponent("tunnels.json")
        let registry = TunnelProcessRegistry(urlProvider: { url }, processIsRunning: { _ in true })
        let profileID = UUID()
        let record = tunnelRecord(profileID: profileID, pid: 123, port: 1083)

        registry.upsert(record)

        XCTAssertEqual(registry.records(), [record])
        XCTAssertEqual(registry.records(for: profileID), [record])
        XCTAssertEqual(try FileProtection.posixPermissions(of: url), FileProtection.privateFilePermissions)

        registry.remove(profileID: profileID, pid: 123)

        XCTAssertTrue(registry.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUpsertReplacesExistingProfilePIDRecord() throws {
        let url = try temporaryDirectory().appendingPathComponent("tunnels.json")
        let registry = TunnelProcessRegistry(urlProvider: { url }, processIsRunning: { _ in true })
        let profileID = UUID()
        let first = tunnelRecord(profileID: profileID, pid: 123, port: 1083)
        let second = tunnelRecord(profileID: profileID, pid: 123, port: 1086)

        registry.upsert(first)
        registry.upsert(second)

        XCTAssertEqual(registry.records(), [second])
    }

    func testPrunesInactiveRecords() throws {
        let url = try temporaryDirectory().appendingPathComponent("tunnels.json")
        var runningPIDs: Set<Int32> = [123]
        let registry = TunnelProcessRegistry(urlProvider: { url }, processIsRunning: { runningPIDs.contains($0) })
        let active = tunnelRecord(profileID: UUID(), pid: 123, port: 1083)
        let inactive = tunnelRecord(profileID: UUID(), pid: 456, port: 1084)

        registry.upsert(active)
        registry.upsert(inactive)
        runningPIDs = [123]
        registry.pruneInactive()

        XCTAssertEqual(registry.records(), [active])
    }

    private func tunnelRecord(profileID: UUID, pid: Int32, port: Int) -> TunnelProcessRecord {
        TunnelProcessRecord(
            profileID: profileID,
            profileName: "Test",
            configuredSocksPort: 1083,
            effectiveSocksPort: port,
            pid: pid,
            command: SSHCommand(arguments: ["-N", "-D", "127.0.0.1:\(port)", "-p", "22", "alice@ssh.example.org"]),
            startedAt: Date(timeIntervalSince1970: TimeInterval(pid))
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-tunnel-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
