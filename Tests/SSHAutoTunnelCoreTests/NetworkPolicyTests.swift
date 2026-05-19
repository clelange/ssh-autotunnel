import XCTest
@testable import SSHAutoTunnelCore

final class NetworkPolicyTests: XCTestCase {
    func testSearchDomainRuleMatches() {
        let match = NetworkMatch(searchDomainContains: "cern.ch")
        let fingerprint = NetworkFingerprint(searchDomains: ["cern.ch"])
        XCTAssertTrue(match.matches(fingerprint))
    }

    func testSSIDRuleRejectsDifferentNetwork() {
        let match = NetworkMatch(wifiSSID: "CERN")
        let fingerprint = NetworkFingerprint(wifiSSID: "Home")
        XCTAssertFalse(match.matches(fingerprint))
    }

    func testDisableRulePrefersWiFiSSID() throws {
        let fingerprint = NetworkFingerprint(wifiSSID: "CERN", searchDomains: ["cern.ch"])
        let rule = try XCTUnwrap(NetworkPolicyRule.disableProxyRule(from: fingerprint))
        XCTAssertEqual(rule.name, "Trusted Wi-Fi: CERN")
        XCTAssertEqual(rule.action, .disableProxy)
        XCTAssertEqual(rule.match.wifiSSID, "CERN")
        XCTAssertNil(rule.match.searchDomainContains)
    }

    func testDisableRuleFallsBackToSearchDomain() throws {
        let fingerprint = NetworkFingerprint(searchDomains: ["cern.ch"])
        let rule = try XCTUnwrap(NetworkPolicyRule.disableProxyRule(from: fingerprint))
        XCTAssertEqual(rule.name, "Trusted domain: cern.ch")
        XCTAssertEqual(rule.match.searchDomainContains, "cern.ch")
    }

    func testDisableRuleReturnsNilForEmptyFingerprint() {
        XCTAssertNil(NetworkPolicyRule.disableProxyRule(from: NetworkFingerprint()))
    }

    func testScopedDisableRuleDisablesOnlyMatchedProfile() throws {
        let profileID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let configuration = AppConfiguration(
            networkRules: [
                NetworkPolicyRule(
                    name: "Home disables profile",
                    match: NetworkMatch(wifiSSID: "Home"),
                    action: .disableProxy,
                    profileID: profileID
                )
            ]
        )
        let decision = NetworkIdentityService(
            commandRunner: { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") },
            wifiSSIDProvider: { nil },
            wifiBSSIDProvider: { nil }
        ).evaluate(configuration: configuration, fingerprint: NetworkFingerprint(wifiSSID: "Home"))

        XCTAssertFalse(decision.shouldDisableProxy)
        XCTAssertEqual(decision.matchedRule?.name, "Home disables profile")
        XCTAssertEqual(decision.disabledProfileIDs, [profileID])
    }

    func testGlobalDisableRuleStillDisablesAllProxyRouting() {
        let configuration = AppConfiguration(
            networkRules: [
                NetworkPolicyRule(
                    name: "Trusted network",
                    match: NetworkMatch(searchDomainContains: "cern.ch"),
                    action: .disableProxy
                )
            ]
        )
        let decision = NetworkIdentityService(
            commandRunner: { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") },
            wifiSSIDProvider: { nil },
            wifiBSSIDProvider: { nil }
        ).evaluate(configuration: configuration, fingerprint: NetworkFingerprint(searchDomains: ["cern.ch"]))

        XCTAssertTrue(decision.shouldDisableProxy)
        XCTAssertEqual(decision.matchedRule?.name, "Trusted network")
        XCTAssertTrue(decision.disabledProfileIDs.isEmpty)
    }
}
