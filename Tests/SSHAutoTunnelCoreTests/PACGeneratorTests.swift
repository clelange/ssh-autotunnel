import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class PACGeneratorTests: XCTestCase {
    func testHealthyProfileReturnsSocks5() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .healthy)]
        ))
        XCTAssertTrue(pac.contains("SOCKS5 127.0.0.1:1088"))
    }

    func testUnhealthyProfileFailsClosedByDefault() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .failed)]
        ))
        XCTAssertTrue(pac.contains(PACGenerator.blockingProxy(port: config.blockingHTTPProxyPort)))
    }

    func testNetworkPolicyDisablesProxy() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .healthy)],
            proxyDisabledByNetworkPolicy: true
        ))
        XCTAssertTrue(pac.contains("return \"DIRECT\";"))
        XCTAssertFalse(pac.contains("SOCKS5 127.0.0.1:1088"))
    }
}
