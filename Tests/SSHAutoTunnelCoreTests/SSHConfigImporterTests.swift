import XCTest
@testable import SSHAutoTunnelCore

final class SSHConfigImporterTests: XCTestCase {
    func testParsesLiteralHostWithCommonConnectionOptions() {
        let entries = SSHConfigParser.parse(
            """
            Host lxplus
              HostName lxplus.cern.ch
              User lange_c
              Port 2222
              ProxyJump bastion.cern.ch
              IdentityFile ~/.ssh/id_lxplus
              IdentitiesOnly yes
            """
        )

        XCTAssertEqual(
            entries,
            [
                SSHConfigEntry(
                    hostPatterns: ["lxplus"],
                    hostName: "lxplus.cern.ch",
                    user: "lange_c",
                    port: 2222,
                    proxyJump: "bastion.cern.ch",
                    extraSSHOptions: ["-i", "~/.ssh/id_lxplus", "-o", "IdentitiesOnly=yes"]
                )
            ]
        )
    }

    func testImporterCreatesProfilesForLiteralHostsAndSkipsWildcards() {
        let (configuration, result) = SSHConfigImporter.apply(
            to: AppConfiguration(),
            configText:
                """
                Host lxplus *.cern.ch !blocked
                  HostName lxplus.cern.ch
                  User lange_c
                  Port 2222

                Host tier3
                  HostName t3ui07.psi.ch
                  ProxyJump t3hop01.psi.ch
                """,
            startingPort: 1200
        )

        XCTAssertEqual(result, SSHConfigImportResult(createdProfiles: 2, updatedProfiles: 0, skippedHosts: 2))
        XCTAssertEqual(configuration.profiles.map(\.name), ["lxplus", "tier3"])
        XCTAssertEqual(configuration.profiles.map(\.localSocksPort), [1200, 1201])
        XCTAssertEqual(configuration.profiles[0].host, "lxplus.cern.ch")
        XCTAssertEqual(configuration.profiles[0].user, "lange_c")
        XCTAssertEqual(configuration.profiles[0].sshPort, 2222)
        XCTAssertEqual(configuration.profiles[1].jumpHost, "t3hop01.psi.ch")
    }

    func testImporterUpdatesExistingProfileWithoutReplacingLocalSettings() {
        let profileID = UUID()
        let existing = TunnelProfile(
            id: profileID,
            name: "lxplus",
            host: "old.example.org",
            localSocksPort: 1444,
            authMode: .kerberosAndTOTP,
            keychain: KeychainReference(account: "me", totpService: "otp")
        )
        let input = AppConfiguration(profiles: [existing])

        let (configuration, result) = SSHConfigImporter.apply(
            to: input,
            configText:
                """
                Host lxplus
                  HostName lxplus.cern.ch
                  User lange_c
                  IdentityFile "~/.ssh/id lxplus"
                """
        )

        XCTAssertEqual(result, SSHConfigImportResult(createdProfiles: 0, updatedProfiles: 1, skippedHosts: 0))
        XCTAssertEqual(configuration.profiles.count, 1)
        XCTAssertEqual(configuration.profiles[0].id, profileID)
        XCTAssertEqual(configuration.profiles[0].host, "lxplus.cern.ch")
        XCTAssertEqual(configuration.profiles[0].user, "lange_c")
        XCTAssertEqual(configuration.profiles[0].localSocksPort, 1444)
        XCTAssertEqual(configuration.profiles[0].authMode, .kerberosAndTOTP)
        XCTAssertEqual(configuration.profiles[0].keychain.totpService, "otp")
        XCTAssertEqual(configuration.profiles[0].extraSSHOptions, ["-i", "~/.ssh/id lxplus"])
    }

    func testImporterExpandsHostNameTokens() {
        let (configuration, result) = SSHConfigImporter.apply(
            to: AppConfiguration(),
            configText:
                """
                Host worker
                  HostName %h.cluster.example.org
                  User alice
                """
        )

        XCTAssertEqual(result.createdProfiles, 1)
        XCTAssertEqual(configuration.profiles[0].host, "worker.cluster.example.org")
    }
}
