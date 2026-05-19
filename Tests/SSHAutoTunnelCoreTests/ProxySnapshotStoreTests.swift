import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class ProxySnapshotStoreTests: XCTestCase {
    func testSavesLoadsAndClearsSnapshot() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        let store = try ProxySnapshotStore(url: url)
        let snapshot = ProxySnapshot(
            serviceName: "Wi-Fi",
            autoProxyEnabled: true,
            autoProxyURL: "http://existing.example/proxy.pac"
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try posixPermissions(of: url.deletingLastPathComponent()), FileProtection.privateDirectoryPermissions)
        XCTAssertEqual(try posixPermissions(of: url), FileProtection.privateFilePermissions)

        try store.clear()

        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSavesAndLoadsAllServiceSnapshots() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        let store = try ProxySnapshotStore(url: url)
        let snapshots = [
            ProxySnapshot(serviceName: "Wi-Fi", autoProxyEnabled: true, autoProxyURL: "http://wifi.example/proxy.pac"),
            ProxySnapshot(serviceName: "USB 10/100/1000 LAN", autoProxyEnabled: false, autoProxyURL: nil)
        ]

        try store.saveAll(snapshots)

        XCTAssertEqual(try store.loadAll(), [
            ProxySnapshot(serviceName: "USB 10/100/1000 LAN", autoProxyEnabled: false, autoProxyURL: nil),
            ProxySnapshot(serviceName: "Wi-Fi", autoProxyEnabled: true, autoProxyURL: "http://wifi.example/proxy.pac")
        ])
    }

    func testLoadsLegacySingleSnapshotFile() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        let store = try ProxySnapshotStore(url: url)
        let snapshot = ProxySnapshot(
            serviceName: "Wi-Fi",
            autoProxyEnabled: true,
            autoProxyURL: "http://existing.example/proxy.pac"
        )
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic])

        XCTAssertEqual(try store.loadAll(), [snapshot])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func posixPermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
