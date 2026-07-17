import Darwin
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class SSHConfigSafeFixServiceTests: XCTestCase {
    func testAppliesSelectedReplacementWithPrivateBackupAndPreservedFormatting() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configURL = sshDirectory.appendingPathComponent("config")
        let original = "# personal routing\n"
            + "Host gateway\n"
            + "  HostName hopx.psi.ch\n"
            + "  User alice\n\n"
            + "Match host \"*.psi.ch\"\n"
            + "\tProxyJump   gateway   # preserve this comment\n"
        try write(original, to: configURL, permissions: 0o640)
        let report = try audit(sshDirectory)
        let finding = try XCTUnwrap(report.safeReplacements.first)
        let service = SSHConfigSafeFixService(
            sshDirectory: sshDirectory,
            now: { Date(timeIntervalSince1970: 0) }
        )

        let preview = try service.preview(report: report, findingIDs: [finding.id])
        XCTAssertEqual(preview.count, 1)
        XCTAssertTrue(preview[0].unifiedDiff.contains("-# personal routing"))
        XCTAssertTrue(preview[0].unifiedDiff.contains("+# personal routing"))

        let result = try service.apply(report: report, findingIDs: [finding.id])

        let adapter = HopAdapterNameResolver.adapterHostBase(profileName: appProfile().name)
        let updated = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("\tProxyJump   \(adapter)   # preserve this comment"))
        XCTAssertTrue(updated.hasPrefix("# personal routing\n"))
        XCTAssertEqual(try FileProtection.posixPermissions(of: configURL), 0o640)
        XCTAssertEqual(result.changedFiles, [configURL.path])
        let backupURL = try XCTUnwrap(result.backupPaths.first.map(URL.init(fileURLWithPath:)))
        XCTAssertEqual(backupURL.lastPathComponent, "config.ssh-autotunnel-audit-backup-19700101-000000.bak")
        XCTAssertEqual(
            try String(contentsOf: backupURL, encoding: .utf8),
            original + "Include config.d/ssh-autotunnel.conf\n"
        )
        XCTAssertEqual(try FileProtection.posixPermissions(of: backupURL), FileProtection.privateFilePermissions)
    }

    func testRejectsContentHashChangeBeforeCreatingBackups() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configURL = sshDirectory.appendingPathComponent("config")
        try write(baseConfig(destination: "one"), to: configURL)
        let report = try audit(sshDirectory)
        let finding = try XCTUnwrap(report.safeReplacements.first)
        try (try String(contentsOf: configURL, encoding: .utf8) + "# changed later\n")
            .write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try SSHConfigSafeFixService(sshDirectory: sshDirectory)
                .apply(report: report, findingIDs: [finding.id])
        ) { error in
            guard case .managedIntegrationChanged(let detail) = error as? SSHConfigSafeFixError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains(configURL.path))
        }
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: sshDirectory.path))
                .allSatisfy { !$0.contains("audit-backup") }
        )
    }

    func testRejectsMetadataChangeAfterAudit() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configURL = sshDirectory.appendingPathComponent("config")
        try write(baseConfig(destination: "one"), to: configURL)
        let report = try audit(sshDirectory)
        let finding = try XCTUnwrap(report.safeReplacements.first)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configURL.path)

        XCTAssertThrowsError(
            try SSHConfigSafeFixService(sshDirectory: sshDirectory)
                .apply(report: report, findingIDs: [finding.id])
        ) { error in
            guard case .managedIntegrationChanged(let detail) = error as? SSHConfigSafeFixError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains(configURL.path))
        }
    }

    func testSymlinkFindingCannotBeApplied() throws {
        let sshDirectory = try temporarySSHDirectory()
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-fix-external-\(UUID().uuidString).conf")
        addTeardownBlock { try? FileManager.default.removeItem(at: externalURL) }
        try write(baseConfig(destination: "one"), to: externalURL)
        let linkURL = sshDirectory.appendingPathComponent("linked.conf")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalURL)
        try write("Include linked.conf\n", to: sshDirectory.appendingPathComponent("config"))
        let report = try audit(sshDirectory)
        let finding = try XCTUnwrap(report.safeReplacements.first)
        XCTAssertFalse(finding.canApply)

        XCTAssertThrowsError(
            try SSHConfigSafeFixService(sshDirectory: sshDirectory)
                .apply(report: report, findingIDs: [finding.id])
        ) { error in
            XCTAssertEqual(error as? SSHConfigSafeFixError, .findingNotSafe(finding.id))
        }
        XCTAssertEqual(try String(contentsOf: externalURL, encoding: .utf8), baseConfig(destination: "one"))
    }

    func testMultiFileFailureRollsBackAlreadyWrittenFiles() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileProtection.protectDirectory(configDirectory)
        try write("""
        Host gateway
          HostName hopx.psi.ch
          User alice
        Include config.d/*.conf
        """ + "\n", to: sshDirectory.appendingPathComponent("config"))
        let firstURL = configDirectory.appendingPathComponent("a.conf")
        let secondURL = configDirectory.appendingPathComponent("b.conf")
        let firstOriginal = "Host one\n  ProxyJump gateway\n"
        let secondOriginal = "Host two\n  ProxyJump gateway\n"
        try write(firstOriginal, to: firstURL)
        try write(secondOriginal, to: secondURL)
        let report = try audit(sshDirectory)
        XCTAssertEqual(report.safeReplacements.count, 2)
        var writeCount = 0
        let service = SSHConfigSafeFixService(
            sshDirectory: sshDirectory,
            now: { Date(timeIntervalSince1970: 0) },
            atomicWriter: { data, url, permissions, _, _ in
                writeCount += 1
                if writeCount == 2 { throw TestWriteError.injected }
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
        )

        XCTAssertThrowsError(
            try service.apply(report: report, findingIDs: Set(report.safeReplacements.map(\.id)))
        ) { error in
            guard let fixError = error as? SSHConfigSafeFixError,
                  case .writeFailed = fixError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(writeCount, 3)
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), firstOriginal)
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), secondOriginal)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configDirectory.appendingPathComponent("a.conf.ssh-autotunnel-audit-backup-19700101-000000.bak").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: configDirectory.appendingPathComponent("b.conf.ssh-autotunnel-audit-backup-19700101-000000.bak").path
        ))
    }

    func testRejectsRemovedManagedIncludeAfterAudit() throws {
        let sshDirectory = try temporarySSHDirectory()
        let configURL = sshDirectory.appendingPathComponent("config")
        try write(baseConfig(destination: "one"), to: configURL)
        let report = try audit(sshDirectory)
        let finding = try XCTUnwrap(report.safeReplacements.first)
        let managedURL = sshDirectory.appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath)
        try FileManager.default.removeItem(at: managedURL)

        XCTAssertThrowsError(
            try SSHConfigSafeFixService(sshDirectory: sshDirectory)
                .apply(report: report, findingIDs: [finding.id])
        ) { error in
            guard case .managedIntegrationChanged(let detail) = error as? SSHConfigSafeFixError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains(managedURL.path))
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), baseConfig(destination: "one") + "Include config.d/ssh-autotunnel.conf\n")
    }

    private func audit(_ sshDirectory: URL) throws -> SSHConfigAuditReport {
        let configuration = AppConfiguration(profiles: [appProfile()])
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileProtection.protectDirectory(configDirectory)
        let managedURL = sshDirectory.appendingPathComponent(SSHConfigSetupService.managedConfigRelativePath)
        try write(try SSHConfigSetupService.managedSnippet(for: configuration), to: managedURL)
        let rootURL = sshDirectory.appendingPathComponent("config")
        let rootPermissions = try XCTUnwrap(FileProtection.posixPermissions(of: rootURL))
        var root = try String(contentsOf: rootURL, encoding: .utf8)
        if !root.hasSuffix("\n") { root.append("\n") }
        root.append("Include config.d/ssh-autotunnel.conf\n")
        try write(root, to: rootURL, permissions: rootPermissions)
        return SSHConfigAuditService(sshDirectory: sshDirectory).check(configuration: configuration)
    }

    private func baseConfig(destination: String) -> String {
        """
        Host gateway
          HostName hopx.psi.ch
          User alice
        Host \(destination)
          ProxyJump gateway
        """ + "\n"
    }

    private func appProfile() -> TunnelProfile {
        TunnelProfile(
            name: "PSI General",
            host: "login.psi.ch",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch",
            keychain: KeychainReference(account: "alice")
        )
    }

    private func temporarySSHDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-fix-tests-\(UUID().uuidString)", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func write(_ text: String, to url: URL, permissions: Int = 0o600) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}

private enum TestWriteError: Error {
    case injected
}
