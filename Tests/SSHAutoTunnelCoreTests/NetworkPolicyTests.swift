import XCTest
@testable import SSHAutoTunnelCore

final class NetworkPolicyTests: XCTestCase {
    func testSearchDomainRuleMatches() {
        let match = NetworkMatch(searchDomainContains: "cern.ch")
        let fingerprint = NetworkFingerprint(searchDomains: ["cern.ch"])
        XCTAssertTrue(match.matches(fingerprint))
    }

    func testSearchDomainSuffixMatchesExactDomainCaseInsensitively() {
        let match = NetworkMatch(searchDomainSuffix: "psi.ch")
        XCTAssertTrue(match.matches(NetworkFingerprint(searchDomains: ["PSI.CH"])))
    }

    func testSearchDomainSuffixMatchesSubdomainAndTrailingDot() {
        let match = NetworkMatch(searchDomainSuffix: "psi.ch.")
        XCTAssertTrue(match.matches(NetworkFingerprint(searchDomains: ["department.psi.ch."])))
    }

    func testSearchDomainSuffixRejectsNonBoundarySuffix() {
        let match = NetworkMatch(searchDomainSuffix: "psi.ch")
        XCTAssertFalse(match.matches(NetworkFingerprint(searchDomains: ["notpsi.ch"])))
    }

    func testSearchDomainSuffixMatchesWiredFingerprintWithoutSSID() {
        let match = NetworkMatch(searchDomainSuffix: "psi.ch")
        let fingerprint = NetworkFingerprint(
            interfaceName: "en8",
            serviceName: "USB 10/100/1000 LAN",
            searchDomains: ["psi.ch"]
        )
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

    func testDirectAccessRulePrefersSearchDomainOverWiFi() throws {
        let profileID = UUID()
        let fingerprint = NetworkFingerprint(wifiSSID: "corp", searchDomains: ["psi.ch"])
        let rule = try XCTUnwrap(NetworkPolicyRule.directAccessRule(from: fingerprint, profileID: profileID))

        XCTAssertEqual(rule.name, "Direct network: psi.ch")
        XCTAssertEqual(rule.action, .directAccess)
        XCTAssertEqual(rule.profileID, profileID)
        XCTAssertEqual(rule.match.searchDomainSuffix, "psi.ch")
        XCTAssertNil(rule.match.wifiSSID)
    }

    func testScopedDirectAccessRulePausesOnlyMatchedProfile() throws {
        let directProfile = TunnelProfile(name: "Direct", host: "direct.psi.ch", localSocksPort: 1088)
        let otherProfile = TunnelProfile(name: "Other", host: "other.example.org", localSocksPort: 1089)
        let configuration = AppConfiguration(
            profiles: [directProfile, otherProfile],
            networkRules: [
                NetworkPolicyRule(
                    name: "PSI internal",
                    match: NetworkMatch(searchDomainSuffix: "psi.ch"),
                    action: .directAccess,
                    profileID: directProfile.id
                )
            ]
        )

        let decision = NetworkIdentityService(
            commandRunner: { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") },
            wifiSSIDProvider: { nil },
            wifiBSSIDProvider: { nil }
        ).evaluate(configuration: configuration, fingerprint: NetworkFingerprint(searchDomains: ["psi.ch"]))

        XCTAssertEqual(decision.directAccessProfileIDs, [directProfile.id])
        XCTAssertEqual(decision.matchedDirectAccessRules.map(\.name), ["PSI internal"])
        XCTAssertFalse(decision.isDirectAccessForAllProfiles)
        XCTAssertFalse(decision.shouldDisableProxy)
    }

    func testGlobalDirectAccessRulePausesEveryConfiguredProfile() {
        let first = TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1088)
        let second = TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1089)
        let configuration = AppConfiguration(
            profiles: [first, second],
            networkRules: [
                NetworkPolicyRule(
                    name: "Office direct",
                    match: NetworkMatch(searchDomainSuffix: "example.org"),
                    action: .directAccess
                )
            ]
        )

        let decision = NetworkIdentityService(
            commandRunner: { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") },
            wifiSSIDProvider: { nil },
            wifiBSSIDProvider: { nil }
        ).evaluate(configuration: configuration, fingerprint: NetworkFingerprint(searchDomains: ["example.org"]))

        XCTAssertEqual(decision.directAccessProfileIDs, [first.id, second.id])
        XCTAssertTrue(decision.isDirectAccessForAllProfiles)
    }

    func testLegacyRoutingRuleRemainsRoutingOnlyAlongsideDirectAccess() {
        let directProfile = TunnelProfile(name: "Direct", host: "direct.psi.ch", localSocksPort: 1088)
        let legacyProfile = TunnelProfile(name: "Legacy", host: "legacy.psi.ch", localSocksPort: 1089)
        let configuration = AppConfiguration(
            profiles: [directProfile, legacyProfile],
            networkRules: [
                NetworkPolicyRule(
                    name: "Direct PSI",
                    match: NetworkMatch(searchDomainSuffix: "psi.ch"),
                    action: .directAccess,
                    profileID: directProfile.id
                ),
                NetworkPolicyRule(
                    name: "Legacy bypass",
                    match: NetworkMatch(searchDomainContains: "psi.ch"),
                    action: .disableProxy,
                    profileID: legacyProfile.id
                )
            ]
        )

        let decision = NetworkIdentityService(
            commandRunner: { _, _ in ShellResult(exitCode: 0, stdout: "", stderr: "") },
            wifiSSIDProvider: { nil },
            wifiBSSIDProvider: { nil }
        ).evaluate(configuration: configuration, fingerprint: NetworkFingerprint(searchDomains: ["psi.ch"]))

        XCTAssertEqual(decision.directAccessProfileIDs, [directProfile.id])
        XCTAssertEqual(decision.disabledProfileIDs, [legacyProfile.id])
    }

    func testDirectAccessRuleRoundTripsThroughJSON() throws {
        let rule = NetworkPolicyRule(
            name: "PSI internal",
            match: NetworkMatch(searchDomainSuffix: "psi.ch"),
            action: .directAccess,
            profileID: UUID()
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(NetworkPolicyRule.self, from: data)

        XCTAssertEqual(decoded, rule)
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
