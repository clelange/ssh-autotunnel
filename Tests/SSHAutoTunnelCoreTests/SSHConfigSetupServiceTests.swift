import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class SSHConfigSetupServiceTests: XCTestCase {
    func testManagedSnippetIncludesJumpHostAndFinalHosts() throws {
        let profile = TunnelProfile(
            name: "PSI CMS Tier-3",
            host: "t3ui07.psi.ch",
            user: "lange_c",
            localSocksPort: 1082,
            interactiveHost: "t3ui08.psi.ch",
            jumpHost: "lange_c@t3hop01.psi.ch",
            keychain: KeychainReference(account: "lange_c")
        )
        let snippet = try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [profile]))

        XCTAssertTrue(snippet.contains("Host t3hop01.psi.ch"))
        XCTAssertTrue(snippet.contains("  User lange_c"))
        XCTAssertTrue(snippet.contains("  ProxyJump none"))
        XCTAssertTrue(snippet.contains("  ControlMaster auto"))
        XCTAssertTrue(snippet.contains("  ControlPath ~/.ssh/sockets/%C"))
        XCTAssertTrue(snippet.contains("Host t3ui07.psi.ch"))
        XCTAssertTrue(snippet.contains("Host t3ui08.psi.ch"))
        XCTAssertTrue(snippet.contains("  ProxyJump lange_c@t3hop01.psi.ch"))
    }

    func testInstallManagedConfigWritesManagedFileAndPrependsIncludeWithBackup() throws {
        let sshDirectory = try temporaryDirectory()
        let configURL = sshDirectory.appendingPathComponent("config")
        try "Host *\n  ControlMaster auto\n".write(to: configURL, atomically: true, encoding: .utf8)
        try FileProtection.protectFile(configURL)
        let profile = TunnelProfile(
            name: "PSI CMS Tier-3",
            host: "t3ui07.psi.ch",
            user: "lange_c",
            localSocksPort: 1082,
            jumpHost: "lange_c@t3hop01.psi.ch",
            keychain: KeychainReference(account: "lange_c")
        )

        let result = try SSHConfigSetupService.installManagedConfig(
            for: AppConfiguration(profiles: [profile]),
            sshDirectory: sshDirectory,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(result.wroteManagedConfig)
        XCTAssertTrue(result.updatedMainConfig)
        XCTAssertEqual(result.profileCount, 1)
        XCTAssertEqual(result.backupURL?.lastPathComponent, "config.ssh-autotunnel-backup-19700101-000000.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.managedConfigURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.backupURL?.path ?? ""))
        XCTAssertEqual(try FileProtection.posixPermissions(of: result.managedConfigURL), FileProtection.privateFilePermissions)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), """
        # SSH AutoTunnel managed include
        Include ~/.ssh/config.d/ssh-autotunnel.conf
        # End SSH AutoTunnel managed include

        Host *
          ControlMaster auto

        """)
    }

    func testInstallManagedConfigIsIdempotentWhenIncludeExists() throws {
        let sshDirectory = try temporaryDirectory()
        let profile = TunnelProfile(
            name: "PSI General",
            host: "login.psi.ch",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch",
            keychain: KeychainReference(account: "alice")
        )
        _ = try SSHConfigSetupService.installManagedConfig(
            for: AppConfiguration(profiles: [profile]),
            sshDirectory: sshDirectory,
            now: Date(timeIntervalSince1970: 0)
        )

        let second = try SSHConfigSetupService.installManagedConfig(
            for: AppConfiguration(profiles: [profile]),
            sshDirectory: sshDirectory,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertFalse(second.wroteManagedConfig)
        XCTAssertFalse(second.updatedMainConfig)
        XCTAssertNil(second.backupURL)
    }

    func testManagedSnippetRejectsUnsafeOpenSSHConfigFields() {
        let profile = TunnelProfile(
            name: "Bad",
            host: "bad host.example.org",
            user: "alice",
            localSocksPort: 1082,
            jumpHost: "alice@t3hop01.psi.ch",
            keychain: KeychainReference(account: "alice")
        )

        XCTAssertThrowsError(try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [profile]))) { error in
            XCTAssertEqual(error as? SSHConfigSetupError, .unsafeField("Profile 'Bad' host"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-autotunnel-ssh-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
