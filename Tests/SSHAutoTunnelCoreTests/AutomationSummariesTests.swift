import XCTest
@testable import SSHAutoTunnelCore

final class AutomationSummariesTests: XCTestCase {
    func testNetworkMatchSummaryIncludesConfiguredFields() {
        let summary = AutomationSummaries.networkMatchSummary(
            NetworkMatch(
                wifiSSID: "CERN",
                serviceNameContains: "Wi-Fi",
                searchDomainContains: "cern.ch",
                gateway: "192.0.2.1",
                vpnRequired: true
            )
        )

        XCTAssertEqual(
            summary,
            "Wi-Fi SSID CERN, service contains Wi-Fi, search domain contains cern.ch, gateway 192.0.2.1, VPN required"
        )
    }

    func testCurrentNetworkSummaryIncludesStableAutomationFields() {
        let summary = AutomationSummaries.currentNetworkSummary(
            NetworkFingerprint(
                interfaceName: "en0",
                serviceName: "Wi-Fi",
                wifiSSID: "CERN",
                gateway: "192.0.2.1",
                dnsServers: ["192.0.2.53"],
                searchDomains: ["cern.ch"],
                ipv4Addresses: ["192.0.2.42"],
                hasVPNInterface: true
            )
        )

        XCTAssertEqual(
            summary,
            "service=Wi-Fi, interface=en0, ssid=CERN, gateway=192.0.2.1, dns=192.0.2.53, searchDomains=cern.ch, ipv4=192.0.2.42, vpn=true"
        )
    }

    func testNetworkActionNamesAreHumanReadable() {
        XCTAssertEqual(AutomationSummaries.networkActionName(.disableProxy), "Disable proxy")
        XCTAssertEqual(AutomationSummaries.networkActionName(.allowProxy), "Allow proxy")
    }
}
