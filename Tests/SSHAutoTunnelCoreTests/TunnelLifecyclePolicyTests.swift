import Darwin
import XCTest
@testable import SSHAutoTunnelCore

final class TunnelLifecyclePolicyTests: XCTestCase {
    func testIntentionalStopSuppressesExitHandling() {
        XCTAssertEqual(
            TunnelLifecyclePolicy.processExitDecision(
                terminationStatus: SIGTERM,
                wasIntentionalStop: true,
                autoReconnect: true
            ),
            .ignore
        )
    }

    func testUnexpectedExitReconnectsWhenEnabled() {
        XCTAssertEqual(
            TunnelLifecyclePolicy.processExitDecision(
                terminationStatus: 255,
                wasIntentionalStop: false,
                autoReconnect: true
            ),
            .reconnect
        )
    }

    func testUnexpectedExitMarksStoppedOrFailedWhenReconnectDisabled() {
        XCTAssertEqual(
            TunnelLifecyclePolicy.processExitDecision(
                terminationStatus: 0,
                wasIntentionalStop: false,
                autoReconnect: false
            ),
            .markStopped
        )
        XCTAssertEqual(
            TunnelLifecyclePolicy.processExitDecision(
                terminationStatus: 255,
                wasIntentionalStop: false,
                autoReconnect: false
            ),
            .markFailed
        )
    }

    func testRepeatedHealthProbeFailureReconnectsWhenEnabled() {
        XCTAssertEqual(
            TunnelLifecyclePolicy.healthProbeFailureDecision(previousHealth: .healthy, autoReconnect: true),
            .markUnhealthy
        )
        XCTAssertEqual(
            TunnelLifecyclePolicy.healthProbeFailureDecision(previousHealth: .unhealthy, autoReconnect: true),
            .reconnect
        )
        XCTAssertEqual(
            TunnelLifecyclePolicy.healthProbeFailureDecision(previousHealth: .unhealthy, autoReconnect: false),
            .markUnhealthy
        )
    }

    func testReconnectDelayBacksOffAndCaps() {
        XCTAssertEqual(TunnelLifecyclePolicy.reconnectDelay(forAttempt: 1), 1)
        XCTAssertEqual(TunnelLifecyclePolicy.reconnectDelay(forAttempt: 3), 4)
        XCTAssertEqual(TunnelLifecyclePolicy.reconnectDelay(forAttempt: 10), 30)
    }
}
