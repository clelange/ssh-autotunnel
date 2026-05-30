import XCTest
@testable import SSHAutoTunnelCore

final class AccountSetupServiceTests: XCTestCase {
    func testPresetsUseAccountSpecificTunnelDefaults() throws {
        let cern = try XCTUnwrap(AccountSetupService.preset(for: .cernLxPlus))
        let tier3 = try XCTUnwrap(AccountSetupService.preset(for: .psiTier3))
        let psi = try XCTUnwrap(AccountSetupService.preset(for: .psiGeneral))

        XCTAssertEqual(cern.credentialHost, "lxplus.cern.ch")
        XCTAssertEqual(cern.interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(cern.defaultTunnelHost, "lxtunnel.cern.ch")
        XCTAssertTrue(cern.defaultTunnelEnabled)

        XCTAssertEqual(tier3.credentialHost, "t3hop01.psi.ch")
        XCTAssertEqual(tier3.defaultTunnelHost, "")
        XCTAssertEqual(tier3.suggestedTunnelHosts, ["t3ui06.psi.ch", "t3ui07.psi.ch"])
        XCTAssertFalse(tier3.defaultTunnelEnabled)

        XCTAssertEqual(psi.credentialHost, "hopx.psi.ch")
        XCTAssertEqual(psi.defaultTunnelHost, "login.psi.ch")
        XCTAssertTrue(psi.defaultTunnelEnabled)
    }

    func testCredentialStatusChecksPasswordAndTOTPWithoutReadingSecrets() {
        let input = AccountSetupInput(
            id: .cernLxPlus,
            username: "clange",
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )
        let status = AccountSetupService.credentialStatus(
            for: input,
            checker: FakePasswordExistenceChecker(results: [
                "cern-lxplus-password|clange": .success(true),
                "cern-lxplus-otp-secret|clange": .success(false)
            ])
        )

        XCTAssertEqual(status.passwordState, .available)
        XCTAssertEqual(status.totpSeedState, .missing)
    }

    func testCredentialStatusMarksUnreadableErrors() {
        let input = AccountSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )
        let status = AccountSetupService.credentialStatus(
            for: input,
            checker: FakePasswordExistenceChecker(results: [
                "psi-general-password|psiuser": .failure(FakeSetupError.denied),
                "psi-general-otp-secret|psiuser": .success(false)
            ])
        )

        XCTAssertEqual(status.passwordState, .unreadable("Access denied"))
        XCTAssertEqual(status.totpSeedState, .missing)
    }

    func testValidationRequiresPasswordForSelectedAccount() {
        let input = AccountSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: false,
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )

        XCTAssertThrowsError(try AccountSetupService.validate([input])) { error in
            XCTAssertEqual(error as? AccountSetupError, .missingPassword(.cernLxPlus))
        }
    }

    func testAppliesCERNAccountWithLxTunnelTargetAndPasswordOnlyAuth() throws {
        let input = AccountSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: true,
            totpSeedAvailable: false,
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )

        let (configuration, result) = try AccountSetupService.apply(inputs: [input], to: AppConfiguration())
        let account = try XCTUnwrap(configuration.accounts.first)
        let profile = try XCTUnwrap(configuration.profiles.first)

        XCTAssertEqual(result.configuredAccounts, 1)
        XCTAssertEqual(result.createdProfiles, 1)
        XCTAssertEqual(account.id, .cernLxPlus)
        XCTAssertEqual(account.interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(account.tunnelHost, "lxtunnel.cern.ch")
        XCTAssertEqual(profile.name, "CERN LxPlus")
        XCTAssertEqual(profile.host, "lxtunnel.cern.ch")
        XCTAssertEqual(profile.interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(profile.user, "clange")
        XCTAssertEqual(profile.authMode, .password)
        XCTAssertEqual(profile.keychain.passwordService, "cern-lxplus-password")
        XCTAssertNil(profile.keychain.totpService)
        XCTAssertEqual(configuration.pacRules.map(\.domainPattern), ["*.cern.ch"])
    }

    func testAppliesPSIGeneralThroughHopxToLoginHost() throws {
        let input = AccountSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            passwordAvailable: true,
            totpSeedAvailable: true,
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )

        let (configuration, _) = try AccountSetupService.apply(inputs: [input], to: AppConfiguration())
        let profile = try XCTUnwrap(configuration.profiles.first)

        XCTAssertEqual(profile.name, "PSI General")
        XCTAssertEqual(profile.host, "login.psi.ch")
        XCTAssertEqual(profile.interactiveHost, "login.psi.ch")
        XCTAssertEqual(profile.jumpHost, "psiuser@hopx.psi.ch")
        XCTAssertEqual(profile.authMode, .passwordAndTOTP)
        XCTAssertEqual(profile.keychain.passwordService, "psi-general-password")
        XCTAssertEqual(profile.keychain.totpService, "psi-general-otp-secret")
        XCTAssertEqual(configuration.pacRules.map(\.domainPattern), ["*.psi.ch"])
    }

    func testTier3SelectedWithoutTunnelStoresCredentialsOnly() throws {
        let input = AccountSetupInput(
            id: .psiTier3,
            username: "tieruser",
            passwordAvailable: true,
            useForTunnelling: false,
            tunnelHost: ""
        )

        let (configuration, _) = try AccountSetupService.apply(inputs: [input], to: AppConfiguration())
        let account = try XCTUnwrap(configuration.accounts.first)

        XCTAssertEqual(account.id, .psiTier3)
        XCTAssertFalse(account.tunnelEnabled)
        XCTAssertTrue(configuration.profiles.isEmpty)
        XCTAssertTrue(configuration.pacRules.isEmpty)
    }

    func testTier3ExactPACRuleIsOrderedBeforeBroadPSIGeneralRule() throws {
        let tier3 = AccountSetupInput(
            id: .psiTier3,
            username: "tieruser",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "worker01.psi.ch"
        )
        let psi = AccountSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )

        let (configuration, _) = try AccountSetupService.apply(inputs: [psi, tier3], to: AppConfiguration())
        let tier3Profile = try XCTUnwrap(configuration.profiles.first { $0.name == "PSI CMS Tier-3" })

        XCTAssertEqual(configuration.pacRules.map(\.domainPattern), ["worker01.psi.ch", "*.psi.ch"])
        XCTAssertEqual(configuration.pacRules.map(\.name), ["PSI Tier-3", "PSI"])
        XCTAssertEqual(tier3Profile.interactiveHost, "worker01.psi.ch")
    }

    func testSkippingPreviouslyConfiguredPresetRemovesGeneratedTunnel() throws {
        let selected = AccountSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )
        let (configured, _) = try AccountSetupService.apply(inputs: [selected], to: AppConfiguration())
        var skipped = selected
        skipped.isSelected = false

        let (configuration, result) = try AccountSetupService.apply(inputs: [skipped], to: configured)

        XCTAssertEqual(result.removedProfiles, 1)
        XCTAssertTrue(configuration.accounts.isEmpty)
        XCTAssertTrue(configuration.profiles.isEmpty)
        XCTAssertTrue(configuration.pacRules.isEmpty)
    }

    func testRepeatedApplyUpdatesExistingProfileInsteadOfDuplicatingIt() throws {
        let input = AccountSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )

        let (first, firstResult) = try AccountSetupService.apply(inputs: [input], to: AppConfiguration())
        let (second, secondResult) = try AccountSetupService.apply(inputs: [input], to: first)

        XCTAssertEqual(firstResult.createdProfiles, 1)
        XCTAssertEqual(secondResult.createdProfiles, 0)
        XCTAssertEqual(secondResult.updatedProfiles, 1)
        XCTAssertEqual(second.profiles.count, 1)
        XCTAssertEqual(second.profiles[0].id, first.profiles[0].id)
        XCTAssertEqual(second.profiles[0].localSocksPort, first.profiles[0].localSocksPort)
    }
}

private struct FakePasswordExistenceChecker: GenericPasswordExistenceChecking {
    var results: [String: Result<Bool, Error>]

    func genericPasswordExists(service: String, account: String) throws -> Bool {
        try results["\(service)|\(account)", default: .success(false)].get()
    }
}

private enum FakeSetupError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Access denied"
    }
}
