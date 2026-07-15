import XCTest
@testable import SSHAutoTunnelCore

final class DirectAccessConnectionIntentTests: XCTestCase {
    func testEnteringDirectAccessPausesProfileWithoutLosingTunnelIntent() {
        let profileID = UUID()
        var intent = DirectAccessConnectionIntent()
        XCTAssertTrue(intent.requestTunnel(profileID))

        let transition = intent.updatePausedProfileIDs([profileID])

        XCTAssertEqual(transition.profileIDsToPause, [profileID])
        XCTAssertTrue(intent.shouldResumeTunnel(profileID))
        XCTAssertTrue(intent.isPaused(profileID))
        XCTAssertFalse(intent.requestTunnel(profileID))
    }

    func testLeavingDirectAccessResumesPreviouslyDesiredTunnelOnce() {
        let profileID = UUID()
        var intent = DirectAccessConnectionIntent(desiredTunnelProfileIDs: [profileID])
        _ = intent.updatePausedProfileIDs([profileID])

        let transition = intent.updatePausedProfileIDs([])
        let repeatedTransition = intent.updatePausedProfileIDs([])

        XCTAssertEqual(transition.tunnelProfileIDsToResume, [profileID])
        XCTAssertTrue(repeatedTransition.tunnelProfileIDsToResume.isEmpty)
    }

    func testDisconnectWhilePausedCancelsResume() {
        let profileID = UUID()
        var intent = DirectAccessConnectionIntent(desiredTunnelProfileIDs: [profileID])
        _ = intent.updatePausedProfileIDs([profileID])

        intent.cancelTunnel(profileID)
        let transition = intent.updatePausedProfileIDs([])

        XCTAssertTrue(transition.tunnelProfileIDsToResume.isEmpty)
    }

    func testConnectOnLaunchCanBeDeferredWhileAlreadyPaused() {
        let profileID = UUID()
        var intent = DirectAccessConnectionIntent(pausedProfileIDs: [profileID])

        intent.deferTunnelUntilDirectAccessEnds(profileID)
        let transition = intent.updatePausedProfileIDs([])

        XCTAssertEqual(transition.tunnelProfileIDsToResume, [profileID])
    }

    func testStandaloneHopResumesOnlyWhenTunnelIsNotAlsoDesired() {
        let tunnelProfileID = UUID()
        let hopOnlyProfileID = UUID()
        var intent = DirectAccessConnectionIntent(
            desiredTunnelProfileIDs: [tunnelProfileID],
            desiredStandaloneHopProfileIDs: [tunnelProfileID, hopOnlyProfileID]
        )
        _ = intent.updatePausedProfileIDs([tunnelProfileID, hopOnlyProfileID])

        let transition = intent.updatePausedProfileIDs([])

        XCTAssertEqual(transition.tunnelProfileIDsToResume, [tunnelProfileID])
        XCTAssertEqual(transition.standaloneHopProfileIDsToResume, [hopOnlyProfileID])
    }
}
