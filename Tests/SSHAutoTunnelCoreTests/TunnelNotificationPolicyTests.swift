import XCTest
@testable import SSHAutoTunnelCore

final class TunnelNotificationPolicyTests: XCTestCase {
    func testNotifiesOnFailureStates() {
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .healthy, current: .unhealthy), .tunnelFailed)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .connecting, current: .failed), .tunnelFailed)
    }

    func testNotifiesOnRecoveryFromProblemStates() {
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .unhealthy, current: .healthy), .tunnelRecovered)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .failed, current: .healthy), .tunnelRecovered)
        XCTAssertEqual(TunnelNotificationPolicy.event(previous: .reconnecting, current: .healthy), .tunnelRecovered)
    }

    func testSuppressesUnchangedAndRoutineTransitions() {
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .healthy, current: .healthy))
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .stopped, current: .connecting))
        XCTAssertNil(TunnelNotificationPolicy.event(previous: .connecting, current: .healthy))
        XCTAssertNil(TunnelNotificationPolicy.event(previous: nil, current: .stopped))
    }
}
