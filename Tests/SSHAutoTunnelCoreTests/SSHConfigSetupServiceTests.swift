import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class SSHConfigSetupServiceTests: XCTestCase {
    func testManagedSnippetIncludesFailClosedAdapterAndFinalHosts() throws {
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
        let endpoint = try HopEndpointKey(profile: profile)
        let controlMaster = try JumpHostControlMasterFactory.make(for: profile)

        XCTAssertTrue(snippet.contains("# SSH AutoTunnel managed SSH config v2"))
        XCTAssertTrue(snippet.contains("Host \(endpoint.adapterHost)"))
        XCTAssertTrue(snippet.contains("  HostName hop-not-connected.start-ssh-autotunnel.invalid"))
        XCTAssertTrue(snippet.contains("  User unused"))
        XCTAssertTrue(snippet.contains("  ProxyJump none"))
        XCTAssertTrue(snippet.contains("  ControlMaster no"))
        XCTAssertTrue(snippet.contains("  ControlPersist no"))
        XCTAssertTrue(snippet.contains("  ControlPath \(controlMaster.controlPath)"))
        XCTAssertTrue(snippet.contains("  BatchMode yes"))
        XCTAssertTrue(snippet.contains("  ClearAllForwardings yes"))
        XCTAssertTrue(snippet.contains("Host t3ui07.psi.ch"))
        XCTAssertTrue(snippet.contains("Host t3ui08.psi.ch"))
        XCTAssertTrue(snippet.contains("  ProxyJump \(endpoint.adapterHost)"))
        XCTAssertFalse(snippet.contains("Host t3hop01.psi.ch"))
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
        XCTAssertNil(result.managedConfigBackupURL)
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
        XCTAssertNil(second.managedConfigBackupURL)
    }

    func testInstallBacksUpExistingManagedConfigBeforeVersionMigration() throws {
        let sshDirectory = try temporaryDirectory()
        let configDirectory = sshDirectory.appendingPathComponent("config.d", isDirectory: true)
        try FileProtection.protectDirectory(configDirectory)
        let managedURL = configDirectory.appendingPathComponent("ssh-autotunnel.conf")
        let legacy = "# SSH AutoTunnel managed SSH config\nHost old-hop\n  ControlMaster auto\n"
        try legacy.write(to: managedURL, atomically: true, encoding: .utf8)
        try FileProtection.protectFile(managedURL)
        let profile = TunnelProfile(
            name: "Generic",
            host: "internal.example.net",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@bastion.example.net",
            keychain: KeychainReference(account: "alice")
        )

        let result = try SSHConfigSetupService.installManagedConfig(
            for: AppConfiguration(profiles: [profile]),
            sshDirectory: sshDirectory,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            result.managedConfigBackupURL?.lastPathComponent,
            "ssh-autotunnel.conf.ssh-autotunnel-backup-19700101-000000.bak"
        )
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(result.managedConfigBackupURL), encoding: .utf8), legacy)
        XCTAssertTrue(try String(contentsOf: managedURL, encoding: .utf8).contains("managed SSH config v2"))
    }

    func testManagedSnippetPoolsProfilesUsingSameEndpoint() throws {
        let first = TunnelProfile(
            name: "One",
            host: "one.internal.example.net",
            user: "alice",
            localSocksPort: 1081,
            jumpHost: "alice@bastion.example.net",
            keychain: KeychainReference(account: "alice")
        )
        var second = first
        second.id = UUID()
        second.name = "Two"
        second.host = "two.internal.example.net"
        second.localSocksPort = 1082
        let endpoint = try HopEndpointKey(profile: first)

        let snippet = try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [first, second]))

        XCTAssertEqual(snippet.components(separatedBy: "Host \(endpoint.adapterHost)\n").count - 1, 1)
        XCTAssertTrue(snippet.contains("Host one.internal.example.net"))
        XCTAssertTrue(snippet.contains("Host two.internal.example.net"))
    }

    func testManagedSnippetRejectsIncompatibleProfilesUsingSameEndpoint() throws {
        let first = TunnelProfile(
            name: "One",
            host: "one.internal.example.net",
            user: "alice",
            localSocksPort: 1081,
            jumpHost: "alice@bastion.example.net",
            hostKeyPolicy: .acceptNew,
            keychain: KeychainReference(account: "alice")
        )
        var second = first
        second.id = UUID()
        second.name = "Two"
        second.host = "two.internal.example.net"
        second.hostKeyPolicy = .strict

        XCTAssertThrowsError(
            try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [first, second]))
        ) { error in
            guard let hopError = error as? HopControlMasterError,
                  case .incompatibleConfiguration = hopError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGeneratedAdapterResolvesToInvalidHostWithoutRunningMaster() throws {
        let sshDirectory = try temporaryDirectory()
        let profile = TunnelProfile(
            name: "Generic",
            host: "internal.example.net",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@bastion.example.net",
            keychain: KeychainReference(account: "alice")
        )
        let endpoint = try HopEndpointKey(profile: profile)
        let configURL = sshDirectory.appendingPathComponent("generated-config")
        try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [profile]))
            .write(to: configURL, atomically: true, encoding: .utf8)

        let resolved = try ShellRunner.run("/usr/bin/ssh", ["-F", configURL.path, "-G", endpoint.adapterHost])

        XCTAssertEqual(resolved.exitCode, 0)
        XCTAssertTrue(resolved.stdout.contains("hostname hop-not-connected.start-ssh-autotunnel.invalid"))
        XCTAssertTrue(resolved.stdout.contains("controlmaster false"))
        XCTAssertTrue(resolved.stdout.contains("batchmode yes"))

        let failedClosed = try ShellRunner.run(
            "/usr/bin/ssh",
            ["-F", configURL.path, "-o", "ConnectTimeout=1", endpoint.adapterHost, "true"]
        )
        XCTAssertNotEqual(failedClosed.exitCode, 0)
        XCTAssertTrue((failedClosed.stdout + failedClosed.stderr).contains("hop-not-connected.start-ssh-autotunnel.invalid"))
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
