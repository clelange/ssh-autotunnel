import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class JumpHostControlMasterTests: XCTestCase {
    func testFactoryBuildsControlMasterAndFinalProxyProfile() throws {
        let profileID = UUID()
        let profile = TunnelProfile(
            id: profileID,
            name: "PSI General",
            host: "login.psi.ch",
            user: "alice",
            sshPort: 2222,
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch",
            authMode: .passwordAndTOTP,
            hostKeyPolicy: .strict,
            extraSSHOptions: ["-o", "LogLevel=DEBUG"]
        )

        let controlMaster = try JumpHostControlMasterFactory.make(for: profile)

        XCTAssertEqual(controlMaster.profileID, profileID)
        XCTAssertEqual(controlMaster.jumpHost, "alice@hopx.psi.ch")
        XCTAssertTrue(controlMaster.controlPath.hasSuffix("/h-\(controlMaster.endpoint.stableHash)/c"))
        XCTAssertEqual(controlMaster.endpoint.adapterHost, "ssh-autotunnel-hop-\(controlMaster.endpoint.stableHash)")
        XCTAssertTrue(controlMaster.command.arguments.containsSubsequence(["-M", "-tt", "-S", controlMaster.controlPath]))
        XCTAssertTrue(controlMaster.command.arguments.containsSubsequence(["-o", "ControlMaster=yes"]))
        XCTAssertTrue(controlMaster.command.arguments.containsSubsequence(["-o", "ClearAllForwardings=yes"]))
        XCTAssertTrue(controlMaster.command.arguments.containsSubsequence(["-o", "StrictHostKeyChecking=yes"]))
        XCTAssertTrue(controlMaster.command.arguments.containsSubsequence(["-o", "PreferredAuthentications=keyboard-interactive,password"]))
        XCTAssertFalse(controlMaster.command.arguments.containsSubsequence(["-o", "LogLevel=DEBUG"]))
        XCTAssertEqual(controlMaster.command.arguments.last, "alice@hopx.psi.ch")

        XCTAssertNil(controlMaster.finalProfile.jumpHost)
        XCTAssertTrue(controlMaster.finalProfile.extraSSHOptions.contains("-o"))
        XCTAssertTrue(controlMaster.finalProfile.extraSSHOptions.contains { option in
            option == "ProxyCommand=/usr/bin/ssh -o ControlMaster=auto -o BatchMode=yes -o ClearAllForwardings=yes -S \(controlMaster.controlPath) -W %h:%p alice@hopx.psi.ch"
        })
        XCTAssertTrue(controlMaster.finalProfile.extraSSHOptions.containsSubsequence(["-o", "LogLevel=DEBUG", "-o"]))
    }

    func testVerboseControlMasterCommandAddsVVVOnlyWhenRequested() throws {
        let profile = TunnelProfile(
            name: "PSI General",
            host: "login.psi.ch",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch",
            extraSSHOptions: ["-o", "LogLevel=DEBUG"]
        )

        let standard = try JumpHostControlMasterFactory.make(for: profile)
        let verbose = try JumpHostControlMasterFactory.make(for: profile, options: SSHLaunchOptions(verbose: true))

        XCTAssertFalse(standard.command.arguments.contains("-vvv"))
        XCTAssertTrue(verbose.command.arguments.contains("-vvv"))
        XCTAssertTrue(verbose.command.arguments.containsSubsequence(["-o", "LogLevel=DEBUG3"]))
        XCTAssertEqual(verbose.command.arguments.last, "alice@hopx.psi.ch")
        XCTAssertFalse(verbose.command.arguments.containsSubsequence(["-o", "LogLevel=DEBUG"]))
    }

    func testFactoryCanApplyExistingControlMasterToDifferentFinalProfile() throws {
        let controlMaster = try JumpHostControlMasterFactory.make(
            for: TunnelProfile(
                name: "Interactive",
                host: "login.psi.ch",
                localSocksPort: 1083,
                jumpHost: "alice@hopx.psi.ch"
            )
        )
        let tunnelProfile = TunnelProfile(
            id: controlMaster.profileID,
            name: "Tunnel",
            host: "service.psi.ch",
            localSocksPort: 1084,
            jumpHost: "alice@hopx.psi.ch"
        )

        let finalProfile = JumpHostControlMasterFactory.profile(tunnelProfile, through: controlMaster)

        XCTAssertEqual(finalProfile.host, "service.psi.ch")
        XCTAssertNil(finalProfile.jumpHost)
        XCTAssertTrue(finalProfile.extraSSHOptions.contains { $0.contains(controlMaster.controlPath) })
    }

    func testTier3ReadinessMarkerCreatesReadyFile() throws {
        let profile = TunnelProfile(
            name: "PSI CMS Tier-3",
            host: "t3ui07.psi.ch",
            localSocksPort: 1082,
            jumpHost: "alice@t3hop01.psi.ch"
        )
        let controlMaster = try JumpHostControlMasterFactory.make(for: profile)
        try? FileManager.default.removeItem(at: controlMaster.directory)
        try FileManager.default.createDirectory(at: controlMaster.directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: controlMaster.directory)
        }
        let marker = try XCTUnwrap(JumpHostReadinessMarker(controlMaster: controlMaster))

        marker.handle(Data("Options (choose number):\n#? ".utf8))

        XCTAssertTrue(FileManager.default.fileExists(atPath: controlMaster.readyPath.path))
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
