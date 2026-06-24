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
        let account = ConnectionTemplateAccount(
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
        let configuration = AppConfiguration(templateAccounts: [account], profiles: [profile])

        let resolved = InteractiveSSHProfileResolver.resolve(profile: profile, in: configuration)

        XCTAssertEqual(resolved.host, "lxplus.cern.ch")
        XCTAssertNil(resolved.jumpHost)
    }

    func testJumpHostPolicyRequiresPersistentSessionsForPSIJumpHosts() {
        XCTAssertTrue(
            InteractiveSSHJumpHostPolicy.requiresPersistentJumpHostSession(
                TunnelProfile(
                    name: "PSI General",
                    host: "login.psi.ch",
                    localSocksPort: 1083,
                    jumpHost: "alice@hopx.psi.ch"
                )
            )
        )
        XCTAssertTrue(
            InteractiveSSHJumpHostPolicy.requiresPersistentJumpHostSession(
                TunnelProfile(
                    name: "PSI CMS Tier-3",
                    host: "t3ui07.psi.ch",
                    localSocksPort: 1082,
                    jumpHost: "alice@t3hop01.psi.ch"
                )
            )
        )
        XCTAssertFalse(
            InteractiveSSHJumpHostPolicy.requiresPersistentJumpHostSession(
                TunnelProfile(name: "CERN", host: "lxplus.cern.ch", localSocksPort: 1081)
            )
        )
    }
}
