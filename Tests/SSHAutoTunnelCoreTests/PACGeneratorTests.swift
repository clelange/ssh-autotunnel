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

    func testScopedNetworkPolicyDisablesOnlyMatchingProfile() {
        let directProfile = TunnelProfile(name: "Direct", host: "direct.example.org", localSocksPort: 1088)
        let tunnelProfile = TunnelProfile(name: "Tunnel", host: "tunnel.example.org", localSocksPort: 1089)
        let config = AppConfiguration(
            profiles: [directProfile, tunnelProfile],
            pacRules: [
                PACRule(name: "Direct", domainPattern: "*.direct.example.org", profileID: directProfile.id),
                PACRule(name: "Tunnel", domainPattern: "*.tunnel.example.org", profileID: tunnelProfile.id)
            ]
        )
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [
                directProfile.id: TunnelRuntimeStatus(profileID: directProfile.id, health: .healthy),
                tunnelProfile.id: TunnelRuntimeStatus(profileID: tunnelProfile.id, health: .healthy)
            ],
            networkDisabledProfileIDs: [directProfile.id]
        ))

        XCTAssertTrue(pac.contains("*.direct.example.org"))
        XCTAssertFalse(pac.contains("SOCKS5 127.0.0.1:1088"))
        XCTAssertTrue(pac.contains("SOCKS5 127.0.0.1:1089"))
    }
}
