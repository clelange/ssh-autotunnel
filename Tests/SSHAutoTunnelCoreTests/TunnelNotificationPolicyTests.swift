import XCTest
@testable import SSHAutoTunnelCore

final class TunnelNotificationPolicyTests: XCTestCase {
    func testNotifiesOnFailureStates() {
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .healthy, current: .unhealthy), .tunnelInterrupted)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .connecting, current: .failed), .tunnelFailed)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .healthy, current: .failed, kind: .hop), .hopFailed)
    }

    func testReconnectCampaignNotificationsAreDeduplicated() {
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .healthy, current: .reconnecting), .tunnelInterrupted)
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .unhealthy, current: .reconnecting))
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .reconnecting, current: .reconnecting))
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .reconnecting, current: .failed), .tunnelReconnectStopped)
        XCTAssertEqual(
            TunnelNotificationPolicy.event(previous: .reconnecting, current: .failed, kind: .hop),
            .hopReconnectStopped
        )
    }

    func testOnlyTerminalEventsOfferTryAgain() {
        XCTAssertFalse(TunnelNotificationEvent.tunnelInterrupted.offersTryAgainAction)
        XCTAssertFalse(TunnelNotificationEvent.hopRecovered.offersTryAgainAction)
        XCTAssertTrue(TunnelNotificationEvent.tunnelReconnectStopped.offersTryAgainAction)
        XCTAssertTrue(TunnelNotificationEvent.hopFailed.offersTryAgainAction)
    }

    func testNotifiesOnRecoveryFromProblemStates() {
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .unhealthy, current: .healthy), .tunnelRecovered)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .failed, current: .healthy), .tunnelRecovered)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .reconnecting, current: .healthy), .tunnelRecovered)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .failed, current: .healthy, kind: .hop), .hopRecovered)
    }

    func testSuppressesUnchangedAndRoutineTransitions() {
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .healthy, current: .healthy))
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .stopped, current: .connecting))
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .connecting, current: .healthy))
        XCTAssertNil(TunnelNotificationPolicy.event(previous: nil, current: .stopped))
    }
}
