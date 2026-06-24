import XCTest
@testable import SSHAutoTunnelCore

final class ConnectionTemplateSetupServiceTests: XCTestCase {
    func testBuiltInTemplatesUseAccountSpecificTunnelDefaults() throws {
        let cern = try XCTUnwrap(ConnectionTemplateSetupService.template(for: .cernLxPlus))
        let tier3 = try XCTUnwrap(ConnectionTemplateSetupService.template(for: .psiTier3))
        let psi = try XCTUnwrap(ConnectionTemplateSetupService.template(for: .psiGeneral))

        XCTAssertEqual(ConnectionTemplateSetupService.templates.map(\.id), [.cernLxPlus, .psiTier3, .psiGeneral])
        XCTAssertEqual(cern.credentialHost, "lxplus.cern.ch")
        XCTAssertEqual(cern.interactiveHost, "lxplus.cern.ch")
        XCTAssertEqual(cern.profileName, "CERN LxPlus")
        XCTAssertEqual(cern.pacRuleName, "CERN")
        XCTAssertEqual(cern.defaultTunnelHost, "lxtunnel.cern.ch")
        XCTAssertTrue(cern.defaultTunnelEnabled)
        XCTAssertNil(cern.jumpHost(username: "clange"))
        XCTAssertEqual(cern.pacDomainPattern(tunnelHost: "lxtunnel.cern.ch"), "*.cern.ch")

        XCTAssertEqual(tier3.credentialHost, "t3hop01.psi.ch")
        XCTAssertEqual(tier3.profileName, "PSI CMS Tier-3")
        XCTAssertEqual(tier3.pacRuleName, "PSI Tier-3")
        XCTAssertEqual(tier3.defaultTunnelHost, "")
        XCTAssertEqual(tier3.suggestedTunnelHosts, ["t3ui06.psi.ch", "t3ui07.psi.ch"])
        XCTAssertFalse(tier3.defaultTunnelEnabled)
        XCTAssertEqual(tier3.jumpHost(username: "tieruser"), "tieruser@t3hop01.psi.ch")
        XCTAssertEqual(tier3.pacDomainPattern(tunnelHost: " worker01.psi.ch "), "worker01.psi.ch")
        XCTAssertNil(tier3.pacDomainPattern(tunnelHost: " "))

        XCTAssertEqual(psi.credentialHost, "hopx.psi.ch")
        XCTAssertEqual(psi.profileName, "PSI General")
        XCTAssertEqual(psi.pacRuleName, "PSI")
        XCTAssertEqual(psi.defaultTunnelHost, "login.psi.ch")
        XCTAssertTrue(psi.defaultTunnelEnabled)
        XCTAssertEqual(psi.jumpHost(username: "psiuser"), "psiuser@hopx.psi.ch")
        XCTAssertEqual(psi.pacDomainPattern(tunnelHost: "login.psi.ch"), "*.psi.ch")
    }

    func testDefaultInputCanBeLoadedForSingleTemplate() throws {
        let input = ConnectionTemplateSetupService.defaultInput(
            for: .psiGeneral,
            in: AppConfiguration(),
            defaultUsername: "psiuser"
        )

        XCTAssertEqual(input.id, .psiGeneral)
        XCTAssertEqual(input.username, "psiuser")
        XCTAssertTrue(input.useForTunnelling)
        XCTAssertEqual(input.tunnelHost, "login.psi.ch")
    }

    func testCredentialStatusChecksPasswordAndTOTPWithoutReadingSecrets() {
        let input = ConnectionTemplateSetupInput(
            id: .cernLxPlus,
            username: "clange",
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )
        let status = ConnectionTemplateSetupService.credentialStatus(
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
        let input = ConnectionTemplateSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )
        let status = ConnectionTemplateSetupService.credentialStatus(
            for: input,
            checker: FakePasswordExistenceChecker(results: [
                "psi-general-password|psiuser": .failure(FakeSetupError.denied),
                "psi-general-otp-secret|psiuser": .success(false)
            ])
        )

        XCTAssertEqual(status.passwordState, .unreadable("Access denied"))
        XCTAssertEqual(status.totpSeedState, .missing)
    }

    func testValidationRequiresPasswordForTemplateSetup() {
        let input = ConnectionTemplateSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: false,
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )

        XCTAssertThrowsError(try ConnectionTemplateSetupService.validate(input)) { error in
            XCTAssertEqual(error as? ConnectionTemplateSetupError, .missingPassword(.cernLxPlus))
        }
    }

    func testAppliesCERNAccountWithLxTunnelTargetAndPasswordOnlyAuth() throws {
        let input = ConnectionTemplateSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: true,
            totpSeedAvailable: false,
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )

        let (configuration, result) = try ConnectionTemplateSetupService.apply(input: input, to: AppConfiguration())
        let account = try XCTUnwrap(configuration.accounts.first)
        let profile = try XCTUnwrap(configuration.profiles.first)

        XCTAssertEqual(result.configuredTemplates, 1)
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
        XCTAssertEqual(configuration.pacRules.map(\.failureMode), [.directFallback])
    }

    func testAppliesPSIGeneralThroughHopxToLoginHost() throws {
        let input = ConnectionTemplateSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            passwordAvailable: true,
            totpSeedAvailable: true,
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )

        let (configuration, _) = try ConnectionTemplateSetupService.apply(input: input, to: AppConfiguration())
        let profile = try XCTUnwrap(configuration.profiles.first)

        XCTAssertEqual(profile.name, "PSI General")
        XCTAssertEqual(profile.host, "login.psi.ch")
        XCTAssertEqual(profile.interactiveHost, "login.psi.ch")
        XCTAssertEqual(profile.jumpHost, "psiuser@hopx.psi.ch")
        XCTAssertEqual(profile.authMode, .passwordAndTOTP)
        XCTAssertEqual(profile.keychain.passwordService, "psi-general-password")
        XCTAssertEqual(profile.keychain.totpService, "psi-general-otp-secret")
        XCTAssertEqual(configuration.pacRules.map(\.domainPattern), ["*.psi.ch"])
        XCTAssertEqual(configuration.pacRules.map(\.failureMode), [.directFallback])
    }

    func testTier3SelectedWithoutTunnelStoresCredentialsOnly() throws {
        let input = ConnectionTemplateSetupInput(
            id: .psiTier3,
            username: "tieruser",
            passwordAvailable: true,
            useForTunnelling: false,
            tunnelHost: ""
        )

        let (configuration, _) = try ConnectionTemplateSetupService.apply(input: input, to: AppConfiguration())
        let account = try XCTUnwrap(configuration.accounts.first)

        XCTAssertEqual(account.id, .psiTier3)
        XCTAssertFalse(account.tunnelEnabled)
        XCTAssertTrue(configuration.profiles.isEmpty)
        XCTAssertTrue(configuration.pacRules.isEmpty)
    }

    func testTier3ExactPACRuleIsOrderedBeforeBroadPSIGeneralRule() throws {
        let tier3 = ConnectionTemplateSetupInput(
            id: .psiTier3,
            username: "tieruser",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "worker01.psi.ch"
        )
        let psi = ConnectionTemplateSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )

        let (withPSI, _) = try ConnectionTemplateSetupService.apply(input: psi, to: AppConfiguration())
        let (configuration, _) = try ConnectionTemplateSetupService.apply(input: tier3, to: withPSI)
        let tier3Profile = try XCTUnwrap(configuration.profiles.first { $0.name == "PSI CMS Tier-3" })

        XCTAssertEqual(configuration.pacRules.map(\.domainPattern), ["worker01.psi.ch", "*.psi.ch"])
        XCTAssertEqual(configuration.pacRules.map(\.name), ["PSI Tier-3", "PSI"])
        XCTAssertEqual(configuration.pacRules.map(\.failureMode), [.directFallback, .directFallback])
        XCTAssertEqual(tier3Profile.interactiveHost, "worker01.psi.ch")
    }

    func testUpdatingExistingGeneratedRulePreservesFailureMode() throws {
        let profile = TunnelProfile(name: "CERN LxPlus", host: "lxtunnel.cern.ch", localSocksPort: 1081)
        let existingRule = PACRule(
            name: "CERN",
            domainPattern: "*.cern.ch",
            profileID: profile.id,
            failureMode: .failClosed
        )
        let input = ConnectionTemplateSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )

        let (configuration, _) = try ConnectionTemplateSetupService.apply(
            input: input,
            to: AppConfiguration(profiles: [profile], pacRules: [existingRule])
        )

        XCTAssertEqual(configuration.pacRules.first?.failureMode, .failClosed)
    }

    func testDisablingTunnellingRemovesGeneratedTunnelAndKeepsAccount() throws {
        let selected = ConnectionTemplateSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "lxtunnel.cern.ch"
        )
        let (configured, _) = try ConnectionTemplateSetupService.apply(input: selected, to: AppConfiguration())
        let credentialsOnly = ConnectionTemplateSetupInput(
            id: .cernLxPlus,
            username: "clange",
            passwordAvailable: true,
            useForTunnelling: false,
            tunnelHost: ""
        )

        let (configuration, result) = try ConnectionTemplateSetupService.apply(input: credentialsOnly, to: configured)

        XCTAssertEqual(result.removedProfiles, 1)
        XCTAssertEqual(configuration.accounts.count, 1)
        XCTAssertFalse(configuration.accounts[0].tunnelEnabled)
        XCTAssertTrue(configuration.profiles.isEmpty)
        XCTAssertTrue(configuration.pacRules.isEmpty)
    }

    func testRepeatedApplyUpdatesExistingProfileInsteadOfDuplicatingIt() throws {
        let input = ConnectionTemplateSetupInput(
            id: .psiGeneral,
            username: "psiuser",
            passwordAvailable: true,
            useForTunnelling: true,
            tunnelHost: "login.psi.ch"
        )

        let (first, firstResult) = try ConnectionTemplateSetupService.apply(input: input, to: AppConfiguration())
        let (second, secondResult) = try ConnectionTemplateSetupService.apply(input: input, to: first)

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
