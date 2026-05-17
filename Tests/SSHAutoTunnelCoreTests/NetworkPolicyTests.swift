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
}
