import XCTest
@testable import SSHAutoTunnelCore

final class SSHPromptResponderTests: XCTestCase {
    func testHostKeyPromptRequestsConfirmation() {
        let prompt = "The authenticity of host 'example.org' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])?"
        XCTAssertEqual(SSHPromptResponder.nextAction(for: prompt), .confirmHostKey)
    }

    func testPasswordPromptsRequestPassword() {
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Password:"), .sendPassword)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "user@example.org's password:"), .sendPassword)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Password for user@example.org:"), .sendPassword)
    }

    func testTOTPPromptsRequestCode() {
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "One-time code:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "(user@lxplus.cern.ch) Your 2nd factor (TOTP):"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Verification code"), .sendTOTP)
    }

    func testAdditionalTwoFactorPromptVariantsRequestCode() {
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Enter PASSCODE:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Authentication code:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Token code:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Enter verification code:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "OTP code:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Enter OTP:"), .sendTOTP)
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "Duo passcode:"), .sendTOTP)
    }

    func testMicrosoftVerificationCodePromptRequestsTOTP() {
        XCTAssertEqual(SSHPromptResponder.nextAction(for: "(user@hopx.psi.ch) Enter Your Microsoft verification code:"), .sendTOTP)
    }

    func testNewestPasswordPromptWinsAfterHostKeyPrompt() {
        let transcript = """
        The authenticity of host 'example.org' can't be established.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        Warning: Permanently added 'example.org' to the list of known hosts.
        user@example.org's password:
        """

        XCTAssertEqual(SSHPromptResponder.nextAction(for: transcript), .sendPassword)
    }

    func testNewestTOTPPromptWinsAfterPasswordPrompt() {
        let transcript = """
        user@example.org's password:
        Verification code:
        """

        XCTAssertEqual(SSHPromptResponder.nextAction(for: transcript), .sendTOTP)
    }

    func testNewestPasswordPromptWinsAfterEarlierTOTPMention() {
        let transcript = """
        Last login required TOTP enrollment.
        user@example.org's password:
        """

        XCTAssertEqual(SSHPromptResponder.nextAction(for: transcript), .sendPassword)
    }

    func testNewestPasswordPromptWinsAfterEarlierPasscodePrompt() {
        let transcript = """
        Duo passcode:
        Permission denied, please try again.
        Password:
        """

        XCTAssertEqual(SSHPromptResponder.nextAction(for: transcript), .sendPassword)
    }

    func testNewestOTPCodePromptWinsAfterPasswordRetry() {
        let transcript = """
        Password:
        Authenticated with partial success.
        OTP code:
        """

        XCTAssertEqual(SSHPromptResponder.nextAction(for: transcript), .sendTOTP)
    }

    func testNonPromptOutputDoesNotRequestAction() {
        XCTAssertNil(SSHPromptResponder.nextAction(for: "Last login: Sun May 17 12:00:00\n[user@host ~]$"))
        XCTAssertNil(SSHPromptResponder.nextAction(for: "Permission denied, please try again."))
    }
}
