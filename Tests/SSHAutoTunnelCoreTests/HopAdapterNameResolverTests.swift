import XCTest
@testable import SSHAutoTunnelCore

final class HopAdapterNameResolverTests: XCTestCase {
    func testBuildsReadableASCIIAdapterSlugs() {
        XCTAssertEqual(
            HopAdapterNameResolver.adapterHostBase(profileName: "  PŠI CMS / Tier_3  "),
            "ssh-autotunnel-hop-psi-cms-tier-3"
        )
        XCTAssertEqual(
            HopAdapterNameResolver.adapterHostBase(profileName: "***"),
            "ssh-autotunnel-hop-profile"
        )
    }

    func testPublishesEachPooledProfileNameForOneEndpoint() throws {
        let first = profile(name: "PSI General", host: "one.psi.ch", jumpHost: "alice@hopx.psi.ch")
        var second = profile(name: "PSI Analysis", host: "two.psi.ch", jumpHost: "alice@hopx.psi.ch")
        second.id = UUID()

        let catalog = HopAdapterNameResolver.resolve(profiles: [first, second])

        XCTAssertEqual(catalog.endpoints.count, 1)
        XCTAssertEqual(
            Set(catalog.endpoints[0].currentAdapterHosts),
            ["ssh-autotunnel-hop-psi-general", "ssh-autotunnel-hop-psi-analysis"]
        )
        XCTAssertEqual(catalog.adapterHost(for: first.id), "ssh-autotunnel-hop-psi-general")
        XCTAssertEqual(catalog.adapterHost(for: second.id), "ssh-autotunnel-hop-psi-analysis")
        XCTAssertEqual(catalog.endpoints[0].adapterHosts.last, try HopEndpointKey(profile: first).adapterHost)
    }

    func testDisambiguatesDuplicateSlugsWithEndpointHost() {
        let first = profile(name: "PSI!", host: "one.psi.ch", jumpHost: "alice@hopx.psi.ch")
        let second = profile(name: "PSI?", host: "two.psi.ch", jumpHost: "alice@t3hop01.psi.ch")

        let catalog = HopAdapterNameResolver.resolve(profiles: [first, second])

        XCTAssertEqual(catalog.adapterHost(for: first.id), "ssh-autotunnel-hop-psi-hopx-psi-ch")
        XCTAssertEqual(catalog.adapterHost(for: second.id), "ssh-autotunnel-hop-psi-t3hop01-psi-ch")
    }

    func testDisambiguatesSameHostWithUserAndPort() {
        let first = profile(name: "Shared", host: "one.example.org", jumpHost: "alice@bastion.example.org")
        var second = profile(name: "Shared", host: "two.example.org", jumpHost: "bob@bastion.example.org")
        second.sshPort = 2222

        let catalog = HopAdapterNameResolver.resolve(profiles: [first, second])

        XCTAssertEqual(
            catalog.adapterHost(for: first.id),
            "ssh-autotunnel-hop-shared-bastion-example-org-alice-22"
        )
        XCTAssertEqual(
            catalog.adapterHost(for: second.id),
            "ssh-autotunnel-hop-shared-bastion-example-org-bob-2222"
        )
    }

    func testRetainsSafeHistoricalAliasesWithoutOverridingCurrentOwners() throws {
        let current = profile(name: "Current", host: "one.example.org", jumpHost: "alice@bastion.example.org")
        let endpoint = try HopEndpointKey(profile: current)

        let catalog = HopAdapterNameResolver.resolve(
            profiles: [current],
            historicalAliases: [endpoint: ["ssh-autotunnel-hop-old-name", "unsafe alias"]]
        )

        XCTAssertEqual(
            catalog.endpoints[0].adapterHosts,
            ["ssh-autotunnel-hop-current", "ssh-autotunnel-hop-old-name", endpoint.adapterHost]
        )
    }

    func testReadableNameNeverShadowsAnotherEndpointsLegacyHash() throws {
        let legacyOwner = profile(
            name: "Legacy Owner",
            host: "one.example.org",
            jumpHost: "alice@legacy.example.org"
        )
        let legacyAlias = try HopEndpointKey(profile: legacyOwner).adapterHost
        let hashText = String(legacyAlias.dropFirst(HopAdapterNameResolver.adapterPrefix.count))
        let collidingName = profile(
            name: hashText,
            host: "two.example.org",
            jumpHost: "alice@readable.example.org"
        )

        let catalog = HopAdapterNameResolver.resolve(profiles: [legacyOwner, collidingName])

        XCTAssertNotEqual(catalog.adapterHost(for: collidingName.id), legacyAlias)
        XCTAssertEqual(
            catalog.adapterHost(for: collidingName.id),
            "\(legacyAlias)-readable-example-org"
        )
    }

    private func profile(name: String, host: String, jumpHost: String) -> TunnelProfile {
        TunnelProfile(
            name: name,
            host: host,
            user: jumpHost.split(separator: "@").first.map(String.init),
            localSocksPort: 1200,
            jumpHost: jumpHost
        )
    }
}
