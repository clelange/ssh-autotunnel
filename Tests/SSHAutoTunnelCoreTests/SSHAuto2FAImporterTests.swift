import XCTest
@testable import SSHAutoTunnelCore

final class SSHAuto2FAImporterTests: XCTestCase {
    func testCreatesProfilesAndPACRulesFromEmptyConfiguration() {
        let (configuration, result) = SSHAuto2FAImporter.apply(to: AppConfiguration(), account: "lange_c")

        XCTAssertEqual(result.createdProfiles, 2)
        XCTAssertEqual(result.updatedProfiles, 0)
        XCTAssertEqual(result.createdPACRules, 2)

        let lxplus = configuration.profiles.first { $0.name == "CERN lxplus" }
        XCTAssertEqual(lxplus?.host, "lxplus.cern.ch")
        XCTAssertEqual(lxplus?.user, "lange_c")
        XCTAssertEqual(lxplus?.authMode, .kerberosAndTOTP)
        XCTAssertEqual(lxplus?.keychain.account, "lange_c")
        XCTAssertEqual(lxplus?.keychain.totpService, "cern-lxplus-otp-secret")

        let tier3 = configuration.profiles.first { $0.name == "PSI Tier-3" }
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
        XCTAssertEqual(lxplus.host, "lxplus.cern.ch")
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
        XCTAssertEqual(tier3.jumpHost, "lange_c@t3hop01.psi.ch")
    }
}
