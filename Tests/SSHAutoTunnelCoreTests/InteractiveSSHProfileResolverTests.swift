import XCTest
@testable import SSHAutoTunnelCore

final class InteractiveSSHProfileResolverTests: XCTestCase {
    func testProfileInteractiveHostOverridesTunnelHost() {
        let profile = TunnelProfile(
            name: "CERN LxPlus",
            host: "lxtunnel.cern.ch",
            localSocksPort: 1081,
            interactiveHost: "lxplus.cern.ch"
        )

        let resolved = InteractiveSSHProfileResolver.resolve(profile: profile, in: AppConfiguration())

        XCTAssertEqual(resolved.host, "lxplus.cern.ch")
        XCTAssertEqual(resolved.jumpHost, profile.jumpHost)
    }

    func testAccountInteractiveHostBackfillsLegacyGeneratedProfile() {
        let profile = TunnelProfile(
            name: "CERN LxPlus",
            host: "lxtunnel.cern.ch",
            localSocksPort: 1081
        )
        let account = AccountConfiguration(
            id: .cernLxPlus,
            displayName: "CERN LxPlus",
            username: "clange",
            credentialHost: "lxplus.cern.ch",
            interactiveHost: "lxplus.cern.ch",
            tunnelEnabled: true,
            tunnelHost: "lxtunnel.cern.ch",
            jumpHost: nil,
            localSocksPort: 1081,
            pacDomainPattern: "*.cern.ch"
        )
        let configuration = AppConfiguration(accounts: [account], profiles: [profile])

        let resolved = InteractiveSSHProfileResolver.resolve(profile: profile, in: configuration)

        XCTAssertEqual(resolved.host, "lxplus.cern.ch")
        XCTAssertNil(resolved.jumpHost)
    }
}
