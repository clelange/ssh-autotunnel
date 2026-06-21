import XCTest
@testable import SSHAutoTunnelCore

final class ProfileTemplateTests: XCTestCase {
    func testExampleTemplateContainsAutomationFields() throws {
        let profile = ProfileTemplate.example()

        XCTAssertEqual(profile.name, "Example tunnel")
        XCTAssertEqual(profile.host, "ssh.example.org")
        XCTAssertEqual(profile.user, "alice")
        XCTAssertEqual(profile.sshPort, 22)
        XCTAssertEqual(profile.localSocksPort, 1083)
        XCTAssertEqual(profile.interactiveHost, "login.example.org")
        XCTAssertEqual(profile.jumpHost, "bastion.example.org")
        XCTAssertEqual(profile.authMode, .passwordAndTOTP)
        XCTAssertEqual(profile.hostKeyPolicy, .acceptNew)
        XCTAssertEqual(profile.keychain.account, "alice")
        XCTAssertEqual(profile.keychain.passwordService, "example-password")
        XCTAssertEqual(profile.keychain.totpService, "example-totp-seed")
        XCTAssertEqual(profile.healthProbe, HealthProbe(host: "ssh.example.org", port: 22))
        XCTAssertEqual(profile.tags, ["example"])
        XCTAssertFalse(profile.connectOnLaunch)
        XCTAssertEqual(profile.notificationPolicy, .failuresAndRecoveries)
        XCTAssertEqual(profile.sshLogLevel, .info)
        XCTAssertFalse(profile.tunnelRequestsRemoteSession)
        XCTAssertEqual(profile.localPortForwardings.map(\.localPort), [15432])
        XCTAssertEqual(profile.localPortForwardings.map(\.targetHost), ["database.internal.example.org"])
        XCTAssertEqual(profile.localPortForwardings.map(\.targetPort), [5432])
        XCTAssertEqual(profile.curatedSSHOptions.identityFiles, ["~/.ssh/id_example"])
        XCTAssertEqual(profile.curatedSSHOptions.forwardAgent, .disabled)
        XCTAssertEqual(profile.extraSSHOptions, ["-o", "IdentitiesOnly=yes"])

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testPACRuleTemplateReferencesProfileTemplate() throws {
        let rule = PACRuleTemplate.example()

        XCTAssertEqual(rule.name, "Example routing")
        XCTAssertEqual(rule.domainPattern, "*.example.org")
        XCTAssertEqual(rule.profileID, ProfileTemplate.exampleProfileID)
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.failureMode, .directFallback)

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(PACRule.self, from: data)
        XCTAssertEqual(decoded, rule)
    }

    func testNetworkRuleTemplateContainsTrustedNetworkFields() throws {
        let rule = NetworkRuleTemplate.example(profileID: ProfileTemplate.exampleProfileID)

        XCTAssertEqual(rule.name, "Example trusted network")
        XCTAssertEqual(rule.match.searchDomainContains, "example.org")
        XCTAssertEqual(rule.action, .disableProxy)
        XCTAssertEqual(rule.profileID, ProfileTemplate.exampleProfileID)
        XCTAssertTrue(rule.enabled)

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(NetworkPolicyRule.self, from: data)
        XCTAssertEqual(decoded, rule)
    }
}
