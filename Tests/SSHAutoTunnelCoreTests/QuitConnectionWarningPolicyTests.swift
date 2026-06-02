import XCTest
@testable import SSHAutoTunnelCore

final class QuitConnectionWarningPolicyTests: XCTestCase {
    func testWarnsForTrackedActiveTunnelAndHop() {
        let profile = TunnelProfile(
            name: "PSI General",
            host: "login.psi.ch",
            localSocksPort: 1084
        )
        let status = TunnelRuntimeStatus(
            profileID: profile.id,
            health: .healthy,
            message: "SOCKS5 handshake succeeded",
            pid: 123
        )
        let hopStatus = HopRuntimeStatus(
            profileID: profile.id,
            jumpHost: "alice@hopx.psi.ch",
            health: .connecting,
            message: "Starting hop",
            pid: 456
        )
        let snapshot = ProfileStatusSnapshot(profile: profile, status: status, hopStatus: hopStatus)

        let warnings = QuitConnectionWarningPolicy.warnings(
            profiles: [snapshot],
            interactiveSessions: [],
            socks5Probe: { _ in
                XCTFail("Probe should not run for tracked active tunnels")
                return false
            }
        )

        XCTAssertEqual(
            warnings,
            [
                QuitConnectionWarning(
                    kind: .tunnel,
                    profileName: "PSI General",
                    detail: "Tunnel healthy (pid 123)",
                    isAppOwnedConnection: true
                ),
                QuitConnectionWarning(
                    kind: .hop,
                    profileName: "PSI General",
                    detail: "Hop via alice@hopx.psi.ch connecting (pid 456)",
                    isAppOwnedConnection: true
                )
            ]
        )
    }

    func testWarnsForUntrackedSOCKSListenerWhenProfileStatusIsStopped() {
        let profile = TunnelProfile(
            name: "CERN LxPlus",
            host: "lxtunnel.cern.ch",
            localSocksPort: 1083
        )
        let snapshot = ProfileStatusSnapshot(
            profile: profile,
            status: TunnelRuntimeStatus(profileID: profile.id, health: .stopped, message: "Stopped")
        )

        let warnings = QuitConnectionWarningPolicy.warnings(
            profiles: [snapshot],
            interactiveSessions: [],
            socks5Probe: { port in port == 1083 }
        )

        XCTAssertEqual(
            warnings,
            [
                QuitConnectionWarning(
                    kind: .untrackedTunnelListener,
                    profileName: "CERN LxPlus",
                    detail: "Untracked SOCKS listener on 127.0.0.1:1083",
                    isAppOwnedConnection: false
                )
            ]
        )
    }

    func testStoppedProfilesWithoutListenerDoNotWarn() {
        let profile = TunnelProfile(
            name: "CERN LxPlus",
            host: "lxtunnel.cern.ch",
            localSocksPort: 1083
        )
        let snapshot = ProfileStatusSnapshot(
            profile: profile,
            status: TunnelRuntimeStatus(profileID: profile.id, health: .stopped, message: "Stopped")
        )

        let warnings = QuitConnectionWarningPolicy.warnings(
            profiles: [snapshot],
            interactiveSessions: [],
            socks5Probe: { _ in false }
        )

        XCTAssertTrue(warnings.isEmpty)
    }

    func testWarnsForInteractiveSessions() {
        let profileID = UUID()
        let session = ActiveInteractiveSSHSession(
            profileID: profileID,
            profileName: "PSI CMS Tier-3",
            jumpHost: "alice@t3hop01.psi.ch"
        )

        let warnings = QuitConnectionWarningPolicy.warnings(
            profiles: [],
            interactiveSessions: [session],
            socks5Probe: { _ in false }
        )

        XCTAssertEqual(
            warnings,
            [
                QuitConnectionWarning(
                    kind: .interactiveSession,
                    profileName: "PSI CMS Tier-3",
                    detail: "Interactive SSH session via alice@t3hop01.psi.ch",
                    isAppOwnedConnection: false
                )
            ]
        )
    }
}
