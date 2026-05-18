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

        try store.clear()

        XCTAssertNil(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
