import XCTest
@testable import SSHAutoTunnelCore

final class SSHConnectionFailureClassifierTests: XCTestCase {
    func testAuthenticationAndHostKeyFailuresAreTerminalBeforeHealth() {
        XCTAssertEqual(
            SSHConnectionFailureClassifier.disposition(
                transcript: "Permission denied, please try again.",
                reachedHealthyState: false
            ),
            .terminal
        )
        XCTAssertEqual(
            SSHConnectionFailureClassifier.disposition(
                transcript: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
                reachedHealthyState: false
            ),
            .terminal
        )
    }

    func testOldPromptFailuresDoNotBlockReconnectAfterHealth() {
        XCTAssertEqual(
            SSHConnectionFailureClassifier.disposition(
                transcript: "Permission denied, please try again.",
                reachedHealthyState: true
            ),
            .retryable
        )
    }
}
