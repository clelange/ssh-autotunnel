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
        XCTAssertTrue(command.arguments.containsSubsequence(["-F", "none"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-D", "127.0.0.1:1090"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ControlMaster=no"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ControlPath=none"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ControlPersist=no"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ForkAfterAuthentication=no"]))
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

    func testInteractiveCommandOmitsTunnelForwarding() {
        let profile = TunnelProfile(
            name: "Interactive",
            host: "target.example.org",
            user: "alice",
            sshPort: 2222,
            localSocksPort: 1091,
            interactiveHost: "login.example.org",
            jumpHost: "alice@bastion.example.org",
            authMode: .passwordAndTOTP
        )

        let command = SSHCommandBuilder.interactiveCommand(for: profile)

        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertFalse(command.arguments.contains("-N"))
        XCTAssertFalse(command.arguments.contains("-D"))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ControlMaster=no"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ControlPath=none"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ControlPersist=no"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ClearAllForwardings=yes"]))
        XCTAssertFalse(command.arguments.contains("ForkAfterAuthentication=no"))
        XCTAssertTrue(command.arguments.containsSubsequence(["-p", "2222"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-J", "alice@bastion.example.org"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "PreferredAuthentications=keyboard-interactive,password"]))
        XCTAssertEqual(command.arguments.last, "alice@login.example.org")
    }

    func testShellCommandQuotesUnsafeArguments() {
        let command = SSHCommand(arguments: [
            "-J",
            "alice@jump.example.org",
            "alice@host with spaces.example.org",
            "-o",
            "ProxyCommand=echo 'quoted'"
        ])

        XCTAssertEqual(
            command.shellCommand,
            "/usr/bin/ssh -J alice@jump.example.org 'alice@host with spaces.example.org' -o 'ProxyCommand=echo '\\''quoted'\\'''"
        )
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

    func testHostKeyPolicyControlsStrictHostKeyChecking() {
        let acceptNewProfile = TunnelProfile(
            name: "Accept",
            host: "ssh.example.org",
            localSocksPort: 1095,
            hostKeyPolicy: .acceptNew
        )
        let strictProfile = TunnelProfile(
            name: "Strict",
            host: "ssh.example.org",
            localSocksPort: 1096,
            hostKeyPolicy: .strict
        )
        let promptProfile = TunnelProfile(
            name: "Prompt",
            host: "ssh.example.org",
            localSocksPort: 1097,
            hostKeyPolicy: .promptAndAccept
        )

        XCTAssertTrue(SSHCommandBuilder.tunnelCommand(for: acceptNewProfile).arguments.containsSubsequence(["-o", "StrictHostKeyChecking=accept-new"]))
        XCTAssertTrue(SSHCommandBuilder.tunnelCommand(for: strictProfile).arguments.containsSubsequence(["-o", "StrictHostKeyChecking=yes"]))
        XCTAssertFalse(SSHCommandBuilder.tunnelCommand(for: promptProfile).arguments.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertFalse(SSHCommandBuilder.tunnelCommand(for: promptProfile).arguments.contains("StrictHostKeyChecking=yes"))
    }

    func testKerberosTOTPEnablesGSSAPIAndKeyboardInteractive() {
        let profile = TunnelProfile(
            name: "Kerberos",
            host: "lxplus.cern.ch",
            localSocksPort: 1093,
            authMode: .kerberosAndTOTP
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertFalse(command.arguments.containsSubsequence(["-o", "PreferredAuthentications=keyboard-interactive,password"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "GSSAPIAuthentication=yes"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "PreferredAuthentications=gssapi-with-mic,keyboard-interactive"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "PasswordAuthentication=no"]))
    }

    func testCERNLxPlusTunnelTargetsLxTunnelDirectly() {
        let profile = TunnelProfile(
            name: "CERN LxPlus",
            host: "lxtunnel.cern.ch",
            user: "clange",
            localSocksPort: 1083,
            interactiveHost: "lxplus.cern.ch",
            authMode: .passwordAndTOTP
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertEqual(command.arguments.last, "clange@lxtunnel.cern.ch")
        XCTAssertTrue(command.arguments.containsSubsequence(["-F", "none"]))
        XCTAssertFalse(command.arguments.contains("-J"))
        XCTAssertFalse(command.arguments.contains { $0.contains("ProxyCommand") })
        XCTAssertFalse(command.arguments.contains { $0.contains("lxplus.cern.ch") })
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

    func testTunnelOwnershipOptionsPrecedeExtraSSHOptions() throws {
        let profile = TunnelProfile(
            name: "Options",
            host: "ssh.example.org",
            localSocksPort: 1094,
            extraSSHOptions: [
                "-o", "ControlMaster=yes",
                "-o", "ControlPath=~/.ssh/sockets/%C",
                "-o", "ControlPersist=600",
                "-o", "ForkAfterAuthentication=yes"
            ]
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertLessThan(
            try XCTUnwrap(command.arguments.firstIndex(of: "ControlMaster=no")),
            try XCTUnwrap(command.arguments.firstIndex(of: "ControlMaster=yes"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(command.arguments.firstIndex(of: "ControlPath=none")),
            try XCTUnwrap(command.arguments.firstIndex(of: "ControlPath=~/.ssh/sockets/%C"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(command.arguments.firstIndex(of: "ControlPersist=no")),
            try XCTUnwrap(command.arguments.firstIndex(of: "ControlPersist=600"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(command.arguments.firstIndex(of: "ForkAfterAuthentication=no")),
            try XCTUnwrap(command.arguments.firstIndex(of: "ForkAfterAuthentication=yes"))
        )
        XCTAssertEqual(command.arguments.last, "ssh.example.org")
    }

    func testVerboseTunnelCommandAddsVVVOnlyWhenRequested() {
        let profile = TunnelProfile(
            name: "Verbose",
            host: "ssh.example.org",
            localSocksPort: 1098
        )

        let standard = SSHCommandBuilder.tunnelCommand(for: profile)
        let verbose = SSHCommandBuilder.tunnelCommand(for: profile, options: SSHLaunchOptions(verbose: true))

        XCTAssertFalse(standard.arguments.contains("-vvv"))
        XCTAssertTrue(verbose.arguments.contains("-vvv"))
        XCTAssertTrue(verbose.arguments.containsSubsequence(["-o", "LogLevel=DEBUG3"]))
        XCTAssertEqual(verbose.arguments.last, "ssh.example.org")
    }

    func testTunnelCanRequestRemoteSessionWhenConfigured() {
        let profile = TunnelProfile(
            name: "Session",
            host: "ssh.example.org",
            localSocksPort: 1099,
            tunnelRequestsRemoteSession: true
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertFalse(command.arguments.contains("-N"))
        XCTAssertTrue(command.arguments.containsSubsequence(["-F", "none"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-D", "127.0.0.1:1099"]))
        XCTAssertEqual(command.arguments.last, "ssh.example.org")
    }

    func testTunnelCommandEmitsEnabledLocalPortForwardings() {
        let profile = TunnelProfile(
            name: "Local",
            host: "ssh.example.org",
            localSocksPort: 1100,
            localPortForwardings: [
                LocalPortForward(bindAddress: "127.0.0.1", localPort: 10201, targetHost: "10.0.0.5", targetPort: 22),
                LocalPortForward(enabled: false, bindAddress: "127.0.0.1", localPort: 10202, targetHost: "10.0.0.6", targetPort: 5432)
            ]
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertTrue(command.arguments.containsSubsequence(["-F", "none"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-L", "127.0.0.1:10201:10.0.0.5:22"]))
        XCTAssertFalse(command.arguments.contains("127.0.0.1:10202:10.0.0.6:5432"))
    }

    func testCuratedSSHOptionsAreMappedToOpenSSHArguments() {
        let profile = TunnelProfile(
            name: "Curated",
            host: "ssh.example.org",
            localSocksPort: 1101,
            jumpHost: "jump.example.org",
            curatedSSHOptions: CuratedSSHOptions(
                bindAddress: "192.0.2.10",
                addressFamily: .ipv4,
                compression: .enabled,
                identityFiles: ["~/.ssh/id_ed25519"],
                certificateFiles: ["~/.ssh/id_ed25519-cert.pub"],
                forwardAgent: .disabled,
                proxyCommand: "ssh bastion -W %h:%p"
            )
        )

        let command = SSHCommandBuilder.tunnelCommand(for: profile)

        XCTAssertTrue(command.arguments.containsSubsequence(["-b", "192.0.2.10"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "AddressFamily=inet"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "Compression=yes"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-i", "~/.ssh/id_ed25519"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "CertificateFile=~/.ssh/id_ed25519-cert.pub"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ForwardAgent=no"]))
        XCTAssertTrue(command.arguments.containsSubsequence(["-o", "ProxyCommand=ssh bastion -W %h:%p"]))
        XCTAssertFalse(command.arguments.contains("-J"))
    }

    func testConfiguredLogLevelAppliesToNormalLaunches() {
        let profile = TunnelProfile(
            name: "Debug",
            host: "ssh.example.org",
            localSocksPort: 1102,
            sshLogLevel: .debug2
        )

        let standard = SSHCommandBuilder.tunnelCommand(for: profile)
        let verbose = SSHCommandBuilder.tunnelCommand(for: profile, options: SSHLaunchOptions(verbose: true))

        XCTAssertTrue(standard.arguments.containsSubsequence(["-o", "LogLevel=DEBUG2"]))
        XCTAssertFalse(standard.arguments.contains("-vvv"))
        XCTAssertTrue(verbose.arguments.containsSubsequence(["-o", "LogLevel=DEBUG3"]))
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
