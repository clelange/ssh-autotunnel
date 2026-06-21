import SSHAutoTunnelCore
import XCTest

final class ProfileDeletionSelectionPolicyTests: XCTestCase {
    func testKeepsSelectedProfileWhenItIsNotBeingDeleted() {
        let profiles = [
            TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1081),
            TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1082),
            TunnelProfile(name: "Third", host: "third.example.org", localSocksPort: 1083)
        ]

        let replacement = ProfileDeletionSelectionPolicy.nearestRemainingProfileID(
            afterDeleting: [profiles[2].id],
            selectedProfileID: profiles[0].id,
            profiles: profiles
        )

        XCTAssertEqual(replacement, profiles[0].id)
    }

    func testSelectsNextProfileWhenDeletingSelectedMiddleProfile() {
        let profiles = [
            TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1081),
            TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1082),
            TunnelProfile(name: "Third", host: "third.example.org", localSocksPort: 1083)
        ]

        let replacement = ProfileDeletionSelectionPolicy.nearestRemainingProfileID(
            afterDeleting: [profiles[1].id],
            selectedProfileID: profiles[1].id,
            profiles: profiles
        )

        XCTAssertEqual(replacement, profiles[2].id)
    }

    func testSelectsPreviousProfileWhenDeletingSelectedLastProfile() {
        let profiles = [
            TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1081),
            TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1082),
            TunnelProfile(name: "Third", host: "third.example.org", localSocksPort: 1083)
        ]

        let replacement = ProfileDeletionSelectionPolicy.nearestRemainingProfileID(
            afterDeleting: [profiles[2].id],
            selectedProfileID: profiles[2].id,
            profiles: profiles
        )

        XCTAssertEqual(replacement, profiles[1].id)
    }

    func testReturnsNilWhenDeletingAllProfiles() {
        let profiles = [
            TunnelProfile(name: "First", host: "first.example.org", localSocksPort: 1081),
            TunnelProfile(name: "Second", host: "second.example.org", localSocksPort: 1082)
        ]

        let replacement = ProfileDeletionSelectionPolicy.nearestRemainingProfileID(
            afterDeleting: profiles.map(\.id),
            selectedProfileID: profiles[0].id,
            profiles: profiles
        )

        XCTAssertNil(replacement)
    }
}
