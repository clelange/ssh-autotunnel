import XCTest
@testable import SSHAutoTunnelCore

final class SSHAuto2FAImporterTests: XCTestCase {
    func testCreatesProfilesAndPACRulesFromEmptyConfiguration() {
        let (configuration, result) = SSHAuto2FAImporter.apply(to: AppConfiguration(), account: "lange_c")

        XCTAssertEqual(result.createdProfiles, 2)
        XCTAssertEqual(result.updatedProfiles, 0)
        XCTAssertEqual(result.createdPACRules, 2)

        let lxplus = configuration.profiles.first { $0.name == "CERN lxplus" }
        XCTAssertEqual(lxplus?.host, "lxtunnel.cern.ch")
        XCTAssertEqual(lxplus?.interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(lxplus?.user, "lange_c")
        XCTAssertEqual(lxplus?.authMode, .kerberosAndTOTP)
        XCTAssertEqual(lxplus?.keychain.account, "lange_c")
        XCTAssertEqual(lxplus?.keychain.totpService, "cern-lxplus-otp-secret")

        let tier3 = configuration.profiles.first { $0.name == "PSI Tier-3" }
        XCTAssertEqual(tier3?.host, "t3ui07.psi.ch")
        XCTAssertEqual(tier3?.interactiveHost, "t3ui07.psi.ch")
        XCTAssertEqual(tier3?.user, "lange_c")
        XCTAssertEqual(tier3?.jumpHost, "lange_c@t3hop01.psi.ch")
        XCTAssertEqual(tier3?.keychain.passwordService, "psit3-password")
        XCTAssertEqual(tier3?.keychain.totpService, "psit3-otp-secret")

        XCTAssertTrue(configuration.pacRules.contains { $0.domainPattern == "*.cern.ch" })
        XCTAssertTrue(configuration.pacRules.contains { $0.domainPattern == "*.psi.ch" })
    }

    func testUpdatesExistingProfilesWithoutChangingIDsOrPorts() throws {
        let existing = TunnelProfile(
            name: "CERN lxplus",
            host: "old.example.org",
            localSocksPort: 1200,
            authMode: .none
        )
        let input = AppConfiguration(profiles: [existing])

        let (configuration, result) = SSHAuto2FAImporter.apply(to: input, account: "lange_c")
        let lxplus = try XCTUnwrap(configuration.profiles.first { $0.name == "CERN lxplus" })

        XCTAssertEqual(result.createdProfiles, 1)
        XCTAssertEqual(result.updatedProfiles, 1)
        XCTAssertEqual(lxplus.id, existing.id)
        XCTAssertEqual(lxplus.localSocksPort, 1200)
        XCTAssertEqual(lxplus.host, "lxtunnel.cern.ch")
        XCTAssertEqual(lxplus.interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(lxplus.user, "lange_c")
        XCTAssertEqual(lxplus.keychain.totpService, "cern-lxplus-otp-secret")
    }

    func testUsesDiscoveredPresetAccounts() throws {
        let (configuration, _) = SSHAuto2FAImporter.apply(
            to: AppConfiguration(),
            account: "clange",
            accountByService: [
                "cern-lxplus-otp-secret": "clange",
                "psit3-password": "lange_c",
                "psit3-otp-secret": "lange_c"
            ]
        )

        let lxplus = try XCTUnwrap(configuration.profiles.first { $0.name == "CERN lxplus" })
        let tier3 = try XCTUnwrap(configuration.profiles.first { $0.name == "PSI Tier-3" })

        XCTAssertEqual(lxplus.keychain.account, "clange")
        XCTAssertEqual(tier3.keychain.account, "lange_c")
        XCTAssertEqual(lxplus.user, "clange")
        XCTAssertEqual(tier3.user, "lange_c")
        XCTAssertEqual(lxplus.interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(tier3.interactiveHost, "t3ui07.psi.ch")
        XCTAssertEqual(tier3.jumpHost, "lange_c@t3hop01.psi.ch")
    }

    func testBackfillsMissingPresetSSHUsersWithoutOverwritingCustomUsers() throws {
        let cern = TunnelProfile(
            name: "CERN lxplus",
            host: "lxplus.cern.ch",
            localSocksPort: 1081,
            keychain: KeychainReference(account: "clange", totpService: "cern-lxplus-otp-secret")
        )
        let psi = TunnelProfile(
            name: "PSI Tier-3",
            host: "t3ui07.psi.ch",
            user: "",
            localSocksPort: 1082,
            jumpHost: "t3hop01.psi.ch",
            keychain: KeychainReference(account: "lange_c", passwordService: "psit3-password", totpService: "psit3-otp-secret")
        )
        let custom = TunnelProfile(
            name: "Custom",
            host: "custom.example.org",
            user: "alice",
            localSocksPort: 1083,
            keychain: KeychainReference(account: "ignored")
        )

        let (configuration, didUpdate) = SSHAuto2FAImporter.backfillPresetSSHUsers(
            in: AppConfiguration(profiles: [cern, psi, custom])
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(configuration.profiles[0].user, "clange")
        XCTAssertEqual(configuration.profiles[1].user, "lange_c")
        XCTAssertEqual(configuration.profiles[1].jumpHost, "lange_c@t3hop01.psi.ch")
        XCTAssertEqual(configuration.profiles[0].host, "lxtunnel.cern.ch")
        XCTAssertEqual(configuration.profiles[0].interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(configuration.profiles[1].interactiveHost, "t3ui07.psi.ch")
        XCTAssertEqual(configuration.profiles[2].user, "alice")
    }
}
