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
        let readableAdapter = HopAdapterNameResolver.adapterHostBase(profileName: profile.name)
        let controlMaster = try JumpHostControlMasterFactory.make(for: profile)

        XCTAssertTrue(snippet.contains("# SSH AutoTunnel managed SSH config v3"))
        XCTAssertTrue(snippet.contains("Host \(readableAdapter) \(endpoint.adapterHost)"))
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
        XCTAssertTrue(snippet.contains("  ProxyJump \(readableAdapter)"))
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

    func testManagedIncludeRequiresUnconditionalScope() {
        let include = "Include config.d/ssh-autotunnel.conf\n"
        for prefix in ["Host unrelated\n", "Host *\n", "Match host unrelated\n", "Match all\n", "Include other.conf\n"] {
            XCTAssertFalse(SSHConfigSetupService.containsManagedInclude(in: prefix + include), prefix)
        }
        XCTAssertFalse(SSHConfigSetupService.containsManagedInclude(in: "Include other.conf # config.d/ssh-autotunnel.conf\n"))
        XCTAssertFalse(SSHConfigSetupService.containsManagedInclude(in: "Include other.conf config.d/ssh-autotunnel.conf\n"))
        XCTAssertTrue(SSHConfigSetupService.containsManagedInclude(in: "# personal config\n\n" + include + "Host example\n"))
        XCTAssertTrue(SSHConfigSetupService.containsManagedInclude(in: "Include=\"~/.ssh/config.d/ssh-autotunnel.conf\" # managed\n"))
    }

    func testInstallRepairsScopedIncludeWithBackupAndIsIdempotent() throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("config")
        let original = "Host unrelated\n  Include config.d/ssh-autotunnel.conf\n"
        try original.write(to: root, atomically: true, encoding: .utf8)
        let configuration = AppConfiguration(profiles: [TunnelProfile(
            name: "General", host: "one.example.org", user: "alice", localSocksPort: 1081,
            jumpHost: "alice@original.example.org"
        )])

        let result = try SSHConfigSetupService.installManagedConfig(for: configuration, sshDirectory: directory)

        XCTAssertTrue(result.updatedMainConfig)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(result.backupURL), encoding: .utf8), original)
        let updated = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(updated.hasPrefix("# SSH AutoTunnel managed include\nInclude ~/.ssh/config.d/ssh-autotunnel.conf\n"))
        XCTAssertTrue(updated.hasSuffix(original))
        XCTAssertFalse(try SSHConfigSetupService.installManagedConfig(for: configuration, sshDirectory: directory).updatedMainConfig)

        // Point OpenSSH at the temporary fixture instead of the real user's ~/.ssh.
        let probe = directory.appendingPathComponent("probe-config")
        try updated.replacingOccurrences(
            of: "~/.ssh/config.d/ssh-autotunnel.conf",
            with: result.managedConfigURL.path
        ).write(to: probe, atomically: true, encoding: .utf8)
        let resolved = try ShellRunner.run("/usr/bin/ssh", ["-F", probe.path, "-G", "ssh-autotunnel-hop-general"])
        XCTAssertEqual(resolved.exitCode, 0)
        XCTAssertTrue(resolved.stdout.contains("hostname hop-not-connected.start-ssh-autotunnel.invalid"))
        XCTAssertTrue(resolved.stdout.contains("controlpath "))
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
        XCTAssertTrue(try String(contentsOf: managedURL, encoding: .utf8).contains("managed SSH config v3"))
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

        let firstAdapter = HopAdapterNameResolver.adapterHostBase(profileName: first.name)
        let secondAdapter = HopAdapterNameResolver.adapterHostBase(profileName: second.name)
        XCTAssertEqual(snippet.components(separatedBy: "  ControlPath ").count - 1, 1)
        XCTAssertTrue(snippet.contains("Host \(firstAdapter) \(secondAdapter) \(endpoint.adapterHost)"))
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
        let readableAdapter = HopAdapterNameResolver.adapterHostBase(profileName: profile.name)
        let configURL = sshDirectory.appendingPathComponent("generated-config")
        try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [profile]))
            .write(to: configURL, atomically: true, encoding: .utf8)

        let resolved = try ShellRunner.run("/usr/bin/ssh", ["-F", configURL.path, "-G", endpoint.adapterHost])

        XCTAssertEqual(resolved.exitCode, 0)
        XCTAssertTrue(resolved.stdout.contains("hostname hop-not-connected.start-ssh-autotunnel.invalid"))
        XCTAssertTrue(resolved.stdout.contains("controlmaster false"))
        XCTAssertTrue(resolved.stdout.contains("batchmode yes"))
        XCTAssertTrue(resolved.stdout.contains("controlpath \(try HopControlPathLayout.default().paths(for: endpoint).controlPath)"))

        let failedClosed = try ShellRunner.run(
            "/usr/bin/ssh",
            ["-F", configURL.path, "-o", "ConnectTimeout=1", endpoint.adapterHost, "true"]
        )
        XCTAssertNotEqual(failedClosed.exitCode, 0)
        XCTAssertTrue((failedClosed.stdout + failedClosed.stderr).contains("hop-not-connected.start-ssh-autotunnel.invalid"))

        let readableResolved = try ShellRunner.run("/usr/bin/ssh", ["-F", configURL.path, "-G", readableAdapter])
        XCTAssertEqual(readableResolved.exitCode, 0)
        XCTAssertTrue(readableResolved.stdout.contains("hostname hop-not-connected.start-ssh-autotunnel.invalid"))
        XCTAssertTrue(readableResolved.stdout.contains("controlpath \(try HopControlPathLayout.default().paths(for: endpoint).controlPath)"))

        let readableFailedClosed = try ShellRunner.run(
            "/usr/bin/ssh",
            ["-F", configURL.path, "-o", "ConnectTimeout=1", readableAdapter, "true"]
        )
        XCTAssertNotEqual(readableFailedClosed.exitCode, 0)
        XCTAssertTrue(
            (readableFailedClosed.stdout + readableFailedClosed.stderr)
                .contains("hop-not-connected.start-ssh-autotunnel.invalid")
        )
    }

    func testManagedSnippetRetainsPriorReadableAliasAfterProfileRename() throws {
        let oldProfile = TunnelProfile(
            name: "PSI Old Name",
            host: "login.psi.ch",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch"
        )
        let oldSnippet = try SSHConfigSetupService.managedSnippet(
            for: AppConfiguration(profiles: [oldProfile])
        )
        var renamedProfile = oldProfile
        renamedProfile.name = "PSI New Name"

        let updated = try SSHConfigSetupService.managedSnippet(
            for: AppConfiguration(profiles: [renamedProfile]),
            preservingAliasesFrom: oldSnippet
        )

        let endpoint = try HopEndpointKey(profile: renamedProfile)
        XCTAssertTrue(updated.contains(
            "Host ssh-autotunnel-hop-psi-new-name ssh-autotunnel-hop-psi-old-name \(endpoint.adapterHost)"
        ))
        XCTAssertTrue(updated.contains("  ProxyJump ssh-autotunnel-hop-psi-new-name"))
    }

    func testRenamingAndReusingNamePreservesOpenSSHControlPathAcrossUpdates() throws {
        let directory = try temporaryDirectory()
        let original = TunnelProfile(
            name: "General", host: "one.example.org", user: "alice", localSocksPort: 1081,
            jumpHost: "alice@original.example.org"
        )
        let oldSnippet = try SSHConfigSetupService.managedSnippet(for: AppConfiguration(profiles: [original]))
        var renamed = original
        renamed.name = "Renamed"
        let newcomer = TunnelProfile(
            name: "General", host: "two.example.org", user: "alice", localSocksPort: 1082,
            jumpHost: "alice@different.example.org"
        )
        let configuration = AppConfiguration(profiles: [renamed, newcomer])
        let updated = try SSHConfigSetupService.managedSnippet(for: configuration, preservingAliasesFrom: oldSnippet)
        XCTAssertEqual(updated, try SSHConfigSetupService.managedSnippet(for: configuration, preservingAliasesFrom: updated))
        let configURL = directory.appendingPathComponent("generated-config")
        try updated.write(to: configURL, atomically: true, encoding: .utf8)

        let originalRoute = try ShellRunner.run("/usr/bin/ssh", ["-F", configURL.path, "-G", "ssh-autotunnel-hop-general"])
        XCTAssertEqual(originalRoute.exitCode, 0)
        let layout = try HopControlPathLayout.default()
        XCTAssertTrue(originalRoute.stdout.contains("controlpath \(try layout.paths(for: HopEndpointKey(profile: original)).controlPath)"))
        let newRoute = try ShellRunner.run("/usr/bin/ssh", ["-F", configURL.path, "-G", "ssh-autotunnel-hop-general-different-example-org"])
        XCTAssertEqual(newRoute.exitCode, 0)
        XCTAssertTrue(newRoute.stdout.contains("controlpath \(try layout.paths(for: HopEndpointKey(profile: newcomer)).controlPath)"))
    }

    func testInstallRejectsReadableAliasDeclaredInUserConfig() throws {
        let sshDirectory = try temporaryDirectory()
        let configURL = sshDirectory.appendingPathComponent("config")
        try "Host ssh-autotunnel-hop-psi-general\n  HostName other.example.org\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        let profile = TunnelProfile(
            name: "PSI General",
            host: "login.psi.ch",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch"
        )

        XCTAssertThrowsError(try SSHConfigSetupService.installManagedConfig(
            for: AppConfiguration(profiles: [profile]),
            sshDirectory: sshDirectory
        )) { error in
            guard case .adapterAliasConflict(let alias, let path, let line) = error as? SSHConfigSetupError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(alias, "ssh-autotunnel-hop-psi-general")
            XCTAssertEqual(path, configURL.path)
            XCTAssertEqual(line, 1)
        }
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
