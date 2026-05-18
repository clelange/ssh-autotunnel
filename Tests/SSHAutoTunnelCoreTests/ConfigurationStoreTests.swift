import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class ConfigurationStoreTests: XCTestCase {
    func testLoadRecoveringBacksUpInvalidConfigurationAndWritesDefaults() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        try Data("{ invalid json".utf8).write(to: url)

        let store = try ConfigurationStore(url: url)
        let result = try store.loadRecovering()

        XCTAssertTrue(result.didRecover)
        XCTAssertNotNil(result.recoveredFromError)
        let backupURL = try XCTUnwrap(result.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "{ invalid json")
        XCTAssertEqual(result.configuration.profiles.map(\.name), ["CERN lxplus", "PSI Tier-3"])

        let recovered = try store.load()
        XCTAssertEqual(recovered.profiles.map(\.name), ["CERN lxplus", "PSI Tier-3"])
    }

    func testLoadRecoveringKeepsValidConfiguration() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        let expected = AppConfiguration(profiles: [
            TunnelProfile(name: "Custom", host: "ssh.example.org", localSocksPort: 1200)
        ])
        let store = try ConfigurationStore(url: url)
        try store.save(expected)

        let result = try store.loadRecovering()

        XCTAssertFalse(result.didRecover)
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(result.configuration, expected)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".invalid-") }
        XCTAssertTrue(backups.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
