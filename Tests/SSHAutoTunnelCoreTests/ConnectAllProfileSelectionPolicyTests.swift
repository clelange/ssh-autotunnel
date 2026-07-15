import XCTest
@testable import SSHAutoTunnelCore

final class ConnectAllProfileSelectionPolicyTests: XCTestCase {
    func testSelectsIncludedInactiveProfilesInConfigurationOrder() {
        let active = profile(name: "Active", port: 1200)
        let excluded = profile(name: "Excluded", port: 1201, includeInConnectAll: false)
        let failed = profile(name: "Failed", port: 1202)
        let stopped = profile(name: "Stopped", port: 1203)

        let selected = ConnectAllProfileSelectionPolicy.profilesToConnect(
            from: [active, excluded, failed, stopped],
            healthByProfileID: [
                active.id: .healthy,
                excluded.id: .stopped,
                failed.id: .failed,
                stopped.id: .stopped
            ]
        )

        XCTAssertEqual(selected.map(\.id), [failed.id, stopped.id])
    }

    func testTreatsConnectingAndStoppingProfilesAsActive() {
        let connecting = profile(name: "Connecting", port: 1200)
        let stopping = profile(name: "Stopping", port: 1201)
        let reconnecting = profile(name: "Reconnecting", port: 1202)

        let selected = ConnectAllProfileSelectionPolicy.profilesToConnect(
            from: [connecting, stopping, reconnecting],
            healthByProfileID: [
                connecting.id: .connecting,
                stopping.id: .stopping,
                reconnecting.id: .reconnecting
            ]
        )

        XCTAssertTrue(selected.isEmpty)
    }

    func testTreatsMissingStatusAsStopped() {
        let profile = profile(name: "New", port: 1200)

        let selected = ConnectAllProfileSelectionPolicy.profilesToConnect(
            from: [profile],
            healthByProfileID: [:]
        )

        XCTAssertEqual(selected.map(\.id), [profile.id])
    }

    private func profile(
        name: String,
        port: Int,
        includeInConnectAll: Bool = true
    ) -> TunnelProfile {
        TunnelProfile(
            name: name,
            host: "\(name.lowercased()).example.org",
            localSocksPort: port,
            includeInConnectAll: includeInConnectAll
        )
    }
}
