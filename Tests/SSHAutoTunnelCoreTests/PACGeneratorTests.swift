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

    func testUnhealthyProfileUsesDirectFallbackByDefault() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .failed)]
        ))
        XCTAssertTrue(pac.contains("return \"DIRECT\";"))
        XCTAssertFalse(pac.contains(PACGenerator.blockingProxy(port: config.blockingHTTPProxyPort)))
    }

    func testUnhealthyProfileCanFailClosed() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(
            name: "Example",
            domainPattern: "*.example.org",
            profileID: profile.id,
            failureMode: .failClosed
        )
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

    func testNetworkPolicyDelegatesToAppendedPACWhenConfigured() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .healthy)],
            proxyDisabledByNetworkPolicy: true,
            appendedPAC: """
            function FindProxyForURL(url, host) {
              return "PROXY existing.example:8080";
            }
            """
        ))

        XCTAssertTrue(pac.contains("var __sshAutoTunnelExistingFindProxyForURL"))
        XCTAssertTrue(pac.contains("var FindProxyForURL;"))
        XCTAssertTrue(pac.contains("return __sshAutoTunnelExistingFindProxyForURL(url, host);"))
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

    func testUnmatchedHostsDelegateToAppendedPAC() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .healthy)],
            appendedPAC: """
            function FindProxyForURL(url, host) {
              return "PROXY existing.example:8080";
            }
            """
        ))

        XCTAssertTrue(pac.contains("return \"SOCKS5 127.0.0.1:1088\";"))
        XCTAssertTrue(pac.contains("return __sshAutoTunnelExistingFindProxyForURL(url, host);"))
        XCTAssertTrue(pac.contains("PROXY existing.example:8080"))
    }

    func testDirectFallbackDelegatesToAppendedPAC() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let rule = PACRule(
            name: "Example",
            domainPattern: "*.example.org",
            profileID: profile.id,
            failureMode: .directFallback
        )
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .failed)],
            appendedPAC: "function FindProxyForURL(url, host) { return \"PROXY existing.example:8080\"; }"
        ))

        XCTAssertTrue(pac.contains("return __sshAutoTunnelExistingFindProxyForURL(url, host);"))
        XCTAssertFalse(pac.contains(PACGenerator.blockingProxy(port: config.blockingHTTPProxyPort)))
    }

    func testRulesAreEmittedInConfiguredOrder() throws {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let broad = PACRule(name: "CERN", domainPattern: "*.cern.ch", profileID: profile.id)
        let docs = PACRule(name: "CERN Docs", domainPattern: "*.docs.cern.ch", profileID: profile.id, failureMode: .failClosed)
        let config = AppConfiguration(profiles: [profile], pacRules: [broad, docs])
        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .failed)]
        ))

        let broadRange = try XCTUnwrap(pac.range(of: #"shExpMatch(host, "*.cern.ch")"#))
        let docsRange = try XCTUnwrap(pac.range(of: #"shExpMatch(host, "*.docs.cern.ch")"#))
        XCTAssertLessThan(broadRange.lowerBound, docsRange.lowerBound)
    }

    func testDomainPatternIsEmittedAsSafeJavaScriptStringLiteral() {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1088)
        let pattern = "*.example.\"quoted\"\\path\u{2028}"
        let rule = PACRule(name: "Quoted", domainPattern: pattern, profileID: profile.id)
        let config = AppConfiguration(profiles: [profile], pacRules: [rule])

        let pac = PACGenerator.generate(context: PACGenerationContext(
            configuration: config,
            statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .healthy)]
        ))

        XCTAssertTrue(pac.contains(#"shExpMatch(host, "*.example.\"quoted\"\\path\u2028")"#))
        XCTAssertFalse(pac.contains(pattern))
    }
}
