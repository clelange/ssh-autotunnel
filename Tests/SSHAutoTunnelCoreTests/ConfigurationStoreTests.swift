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
        XCTAssertEqual(try posixPermissions(of: backupURL), FileProtection.privateFilePermissions)
        XCTAssertEqual(try posixPermissions(of: url), FileProtection.privateFilePermissions)
        XCTAssertTrue(result.configuration.templateAccounts.isEmpty)
        XCTAssertTrue(result.configuration.profiles.isEmpty)

        let recovered = try store.load()
        XCTAssertTrue(recovered.templateAccounts.isEmpty)
        XCTAssertTrue(recovered.profiles.isEmpty)
    }

    func testLoadRecoveringKeepsValidConfiguration() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        let expected = AppConfiguration(profiles: [
            TunnelProfile(name: "Custom", host: "ssh.example.org", localSocksPort: 1200)
        ])
        let store = try ConfigurationStore(url: url)
        try store.save(expected)
        XCTAssertEqual(try posixPermissions(of: directory), FileProtection.privateDirectoryPermissions)
        XCTAssertEqual(try posixPermissions(of: url), FileProtection.privateFilePermissions)

        let result = try store.loadRecovering()

        XCTAssertFalse(result.didRecover)
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(result.configuration, expected)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".invalid-") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testLoadMigratesMissingPresetSSHUsers() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        let legacy = AppConfiguration(profiles: [
            TunnelProfile(
                name: "CERN lxplus",
                host: "lxplus.cern.ch",
                localSocksPort: 1081,
                keychain: KeychainReference(account: "clange", totpService: "cern-lxplus-otp-secret")
            ),
            TunnelProfile(
                name: "PSI Tier-3",
                host: "t3ui07.psi.ch",
                localSocksPort: 1082,
                jumpHost: "t3hop01.psi.ch",
                keychain: KeychainReference(account: "lange_c", passwordService: "psit3-password", totpService: "psit3-otp-secret")
            )
        ])
        let store = try ConfigurationStore(url: url)
        try store.save(legacy)

        let migrated = try store.load()
        let persisted = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))

        XCTAssertEqual(migrated.profiles[0].user, "clange")
        XCTAssertEqual(migrated.profiles[0].host, "lxtunnel.cern.ch")
        XCTAssertEqual(migrated.profiles[0].interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(migrated.profiles[1].user, "lange_c")
        XCTAssertEqual(migrated.profiles[1].jumpHost, "lange_c@t3hop01.psi.ch")
        XCTAssertEqual(migrated.profiles[1].interactiveHost, "t3ui07.psi.ch")
        XCTAssertEqual(persisted, migrated)
    }

    func testBackupCurrentConfigurationCopiesPrivateConfig() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        let expected = AppConfiguration(profiles: [
            TunnelProfile(name: "Custom", host: "ssh.example.org", localSocksPort: 1200)
        ])
        let store = try ConfigurationStore(url: url)
        try store.save(expected)

        let backupURL = try XCTUnwrap(store.backupCurrentConfiguration(label: "pre-import"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertTrue(backupURL.lastPathComponent.contains(".pre-import-"))
        XCTAssertEqual(try posixPermissions(of: backupURL), FileProtection.privateFilePermissions)
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: backupURL)), expected)
        XCTAssertEqual(try store.load(), expected)
    }

    func testBackupCurrentConfigurationReturnsNilWhenConfigIsMissing() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        let store = try ConfigurationStore(url: url)

        XCTAssertNil(try store.backupCurrentConfiguration(label: "pre-import"))
    }

    func testPruneBackupsKeepsNewestMatchingBackupsOnly() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        let store = try ConfigurationStore(url: url)

        for index in 0..<12 {
            try writeBackup(
                named: String(format: "config.json.pre-import-2026-01-01T00-00-%02d.000Z", index),
                in: directory
            )
        }
        try writeBackup(named: "config.json.invalid-2026-01-01T00-00-00.000Z", in: directory)

        let removed = try store.pruneBackups(label: "pre-import", keeping: 10)

        XCTAssertEqual(
            removed.map(\.lastPathComponent),
            [
                "config.json.pre-import-2026-01-01T00-00-00.000Z",
                "config.json.pre-import-2026-01-01T00-00-01.000Z"
            ]
        )
        XCTAssertEqual(try matchingBackups(in: directory, label: "pre-import").count, 10)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("config.json.invalid-2026-01-01T00-00-00.000Z").path
            )
        )
    }

    func testBackupCurrentConfigurationCanPruneOldPreImportBackups() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config.json")
        let expected = AppConfiguration(profiles: [
            TunnelProfile(name: "Custom", host: "ssh.example.org", localSocksPort: 1200)
        ])
        let store = try ConfigurationStore(url: url)
        try store.save(expected)

        for index in 0..<10 {
            try writeBackup(
                named: String(format: "config.json.pre-import-2000-01-01T00-00-%02d.000Z", index),
                in: directory
            )
        }

        let backupURL = try XCTUnwrap(store.backupCurrentConfiguration(label: "pre-import", retaining: 3))
        let remainingBackups = try matchingBackups(in: directory, label: "pre-import")

        XCTAssertEqual(remainingBackups.count, 3)
        XCTAssertTrue(remainingBackups.contains(backupURL.lastPathComponent))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("config.json.pre-import-2000-01-01T00-00-00.000Z").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("config.json.pre-import-2000-01-01T00-00-09.000Z").path
            )
        )
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

    private func writeBackup(named fileName: String, in directory: URL) throws {
        try Data("{}".utf8).write(to: directory.appendingPathComponent(fileName))
    }

    private func matchingBackups(in directory: URL, label: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("config.json.\(label)-") }
            .sorted()
    }
}
