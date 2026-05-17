import XCTest
@testable import SSHAutoTunnelCore

final class SSHPromptResponderTests: XCTestCase {
    func testHostKeyPromptRequestsConfirmation() {
        let prompt = "The authenticity of host 'example.org' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])?"
        XCTAssertEqual(SSHPromptResponder.nextAction(for: prompt), .confirmHostKey)
    }

    func testPasswordPromptsRequestPassword() {
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "user@example.org's password:"), .sendPassword)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Password for user@example.org:"), .sendPassword)
    }

    func testTOTPPromptsRequestCode() {
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "One-time code:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "(user@lxplus.cern.ch) Your 2nd factor (TOTP):"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Verification code"), .sendTOTP)
    }

    func testNonPromptOutputDoesNotRequestAction() {
        XCTAssertNil(SSHPromptResponder.nextAction(for: "Last login: Sun May 17 12:00:00\n[user@host ~]$"))
        XCTAssertNil(SSHPromptResponder.nextAction(for: "Permission denied, please try again."))
    }
}
