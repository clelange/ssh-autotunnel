import XCTest
@testable import SSHAutoTunnelCore

final class SSHCommandBuilderTests: XCTestCase {
    func testGenericTunnelCommand() {
        let profile = TunnelProfile(
            name: "Generic",
            host: "ssh.example.org",
            user: "alice",
            sshPort: 2222,
            localSocksPort: 1090
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertEqual(command.arguments.first, "-N")
        XCTAssertTrue(command.arguments.containsSubsequence(["-D", "127.0.0.1:1090"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-p", "2222"]))
        XCTAssertEqual(command.arguments.last, "alice@ssh.example.org")
        XCTAssertFalse(command.arguments.contains("-J"))
    }

    func testJumpHostCommand() {
        let profile = TunnelProfile(
            name: "Jump",
            host: "target.example.org",
            localSocksPort: 1091,
            jumpHost: "bastion.example.org"
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertTrue(command.arguments.containsSubsequence(["-J", "bastion.example.org"]))
        XCTAssertEqual(command.arguments.last, "target.example.org")
    }

    func testPasswordAuthRequestsKeyboardInteractive() {
        let profile = TunnelProfile(
            name: "Password",
            host: "ssh.example.org",
            localSocksPort: 1092,
            authMode: .passwordAndTOTP
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "PreferredAuthentications=keyboard-interactive,password"]))
    }

    func testKerberosTOTPDoesNotForcePasswordAuth() {
        let profile = TunnelProfile(
            name: "Kerberos",
            host: "lxplus.cern.ch",
            localSocksPort: 1093,
            authMode: .kerberosAndTOTP
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertFalse(command.arguments.containsSubsequence(["-o", "PreferredAuthentications=keyboard-interactive,password"]))
    }

    func testExtraOptionsArePreservedBeforeDestination() {
        let profile = TunnelProfile(
            name: "Options",
            host: "ssh.example.org",
            localSocksPort: 1094,
            extraSSHOptions: ["-o", "LogLevel=DEBUG"]
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "LogLevel=DEBUG", "ssh.example.org"]))
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        for start in 0...(count - subsequence.count) {
            if Array(self[start..<(start + subsequence.count)]) == subsequence {
                return true
            }
        }
        return false
    }
}
