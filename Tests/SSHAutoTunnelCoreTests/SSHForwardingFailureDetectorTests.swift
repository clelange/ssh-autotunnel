import XCTest
@testable import SSHAutoTunnelCore

final class SSHForwardingFailureDetectorTests: XCTestCase {
    func testDetectsCERNLocalForwardingPortConflictTranscript() throws {
        let transcript = """
        (clange@lxtunnel.cern.ch) Your 2nd factor (clange): <redacted>
        bind [127.0.0.1]:12345: Address already in use\r
        channel_setup_fwd_listener_tcpip: cannot listen to port: 12345\r
        Could not request local forwarding.\r
        """

        let failure = try XCTUnwrap(SSHForwardingFailureDetector.detect(in: transcript))

        XCTAssertEqual(failure.port, 12345)
        XCTAssertTrue(failure.addressAlreadyInUse)
        XCTAssertEqual(
            failure.statusDetail,
            "Local forwarding failed: port 12345 is already in use (check SSH config LocalForward/DynamicForward entries or another process using the port)"
        )
    }

    func testIgnoresUnrelatedSSHOutput() {
        let transcript = """
        Permission denied, please try again.
        Could not resolve hostname example.invalid: nodename nor servname provided, or not known
        """

        XCTAssertNil(SSHForwardingFailureDetector.detect(in: transcript))
    }
}
