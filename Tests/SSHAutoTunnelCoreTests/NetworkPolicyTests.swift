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
}
