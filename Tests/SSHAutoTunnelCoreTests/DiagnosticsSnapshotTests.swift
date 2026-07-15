import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class DiagnosticsSnapshotTests: XCTestCase {
    func testDiagnosticsSnapshotRoundTripsThroughJSON() throws {
        let profileID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let profile = TunnelProfile(id: profileID, name: "PSI General", host: "login.psi.ch", localSocksPort: 1081, jumpHost: "alice@hopx.psi.ch")
        let status = TunnelRuntimeStatus(profileID: profileID, health: .healthy, message: "SOCKS5 OK", pid: 42)
        let hopIssue = HopConnectionIssue(
            code: .foreignControlSocket,
            summary: "Foreign socket",
            detail: "The socket is not owned by SSH AutoTunnel.",
            recoverySuggestion: "Choose a different socket path or remove it after verifying ownership.",
            retryable: false
        )
        let hopStatus = HopRuntimeStatus(
            profileID: profileID,
            jumpHost: "alice@hopx.psi.ch",
            health: .failed,
            message: "Hop conflict",
            pid: 41,
            ownership: .adoptedAppOwned,
            issue: hopIssue
        )
        let snapshot = DiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appIdentifier: "dev.clange.ssh-autotunnel",
            pacURL: "http://127.0.0.1:18483/proxy.pac",
            statusURL: "http://127.0.0.1:18483/status",
            proxyApplyMode: .activeNetworkServicePAC,
            systemPACStatus: SystemPACStatus(
                serviceName: "Wi-Fi",
                expectedPACURL: "http://127.0.0.1:18483/proxy.pac",
                observedPACURL: "http://127.0.0.1:18483/proxy.pac",
                autoProxyEnabled: true,
                state: .active
            ),
            proxyDisabledByNetworkPolicy: true,
            matchedNetworkRule: "Trusted Wi-Fi: CERN",
            directAccessProfileIDs: [profileID],
            matchedDirectAccessRules: ["PSI internal"],
            configuredPorts: LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484),
            activePorts: LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484),
            currentNetwork: NetworkFingerprint(serviceName: "Wi-Fi", wifiSSID: "CERN", hasVPNInterface: true),
            profiles: [ProfileStatusSnapshot(profile: profile, status: status, hopStatus: hopStatus)],
            fileStatuses: [
                DiagnosticFileStatus(
                    label: "Configuration",
                    path: "/tmp/config.json",
                    exists: true,
                    posixPermissions: "600",
                    isPrivate: true
                )
            ],
            systemProxySnapshotExists: false
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.profiles.first?.hop?.ownership, .adoptedAppOwned)
        XCTAssertEqual(decoded.profiles.first?.hop?.issue, hopIssue)
        XCTAssertEqual(decoded.directAccessProfileIDs, [profileID])
        XCTAssertEqual(decoded.matchedDirectAccessRules, ["PSI internal"])
    }

    func testAppStatusSnapshotCarriesSystemPACStatus() throws {
        let snapshot = AppStatusSnapshot(
            pacURL: "http://127.0.0.1:18483/proxy.pac",
            systemPACStatus: SystemPACStatus(
                serviceName: "Wi-Fi",
                expectedPACURL: "http://127.0.0.1:18483/proxy.pac",
                observedPACURL: nil,
                autoProxyEnabled: false,
                state: .notConfigured
            ),
            proxyDisabledByNetworkPolicy: false,
            matchedNetworkRule: nil,
            profiles: []
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppStatusSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.systemPACStatus?.state, .notConfigured)
    }

    func testProfileStatusSnapshotCarriesEffectiveRuntimeSocksPort() throws {
        let profileID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let profile = TunnelProfile(id: profileID, name: "CERN LxPlus", host: "lxtunnel.cern.ch", localSocksPort: 1083)
        let status = TunnelRuntimeStatus(
            profileID: profileID,
            health: .healthy,
            message: "SOCKS5 OK",
            effectiveLocalSocksPort: 1084
        )
        let snapshot = ProfileStatusSnapshot(profile: profile, status: status)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProfileStatusSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.localSocksPort, 1083)
        XCTAssertEqual(decoded.effectiveLocalSocksPort, 1084)
    }

    func testProfileStatusSnapshotCarriesRedesignFields() throws {
        let profileID = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let profile = TunnelProfile(
            id: profileID,
            name: "Work",
            host: "ssh.example.org",
            localSocksPort: 1083,
            interactiveHost: "login.example.org",
            jumpHost: "jump.example.org",
            tags: ["infrastructure"],
            connectOnLaunch: true,
            notificationPolicy: .allStatusChanges,
            sshLogLevel: .debug2,
            tunnelRequestsRemoteSession: true,
            localPortForwardings: [
                LocalPortForward(localPort: 10201, targetHost: "10.0.0.5", targetPort: 22)
            ],
            curatedSSHOptions: CuratedSSHOptions(proxyCommand: "ssh jump -W %h:%p", maxReconnectAttempts: 2)
        )
        let status = TunnelRuntimeStatus(profileID: profileID, health: .healthy, message: "OK")

        let snapshot = ProfileStatusSnapshot(profile: profile, status: status)

        XCTAssertEqual(snapshot.interactiveHost, "login.example.org")
        XCTAssertEqual(snapshot.jumpHost, "jump.example.org")
        XCTAssertEqual(snapshot.tags, ["infrastructure"])
        XCTAssertTrue(snapshot.connectOnLaunch)
        XCTAssertEqual(snapshot.notificationPolicy, .allStatusChanges)
        XCTAssertEqual(snapshot.sshLogLevel, .debug2)
        XCTAssertTrue(snapshot.tunnelRequestsRemoteSession)
        XCTAssertEqual(snapshot.localPortForwardings.map(\.localPort), [10201])
        XCTAssertEqual(snapshot.curatedSSHOptions.maxReconnectAttempts, 2)
    }

    func testControlResponseCanCarryDiagnostics() throws {
        let diagnostics = DiagnosticsSnapshot(
            appIdentifier: "dev.clange.ssh-autotunnel",
            pacURL: "http://127.0.0.1:18483/proxy.pac",
            statusURL: "http://127.0.0.1:18483/status",
            proxyApplyMode: .manual,
            proxyDisabledByNetworkPolicy: false,
            matchedNetworkRule: nil,
            configuredPorts: LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484),
            activePorts: nil,
            currentNetwork: NetworkFingerprint(),
            profiles: [],
            fileStatuses: [],
            systemProxySnapshotExists: false
        )
        let response = ControlResponse(ok: true, message: "Diagnostics", diagnostics: diagnostics)

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.message, "Diagnostics")
        XCTAssertEqual(decoded.diagnostics, diagnostics)
    }

    func testControlResponseCanCarryConfigurationExportAndSupportBundle() throws {
        let configuration = AppConfiguration(apiToken: "local-token")
        let export = ConfigurationExportService.makeExport(
            from: configuration,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_002),
            appIdentifier: "dev.clange.ssh-autotunnel"
        )
        let bundle = ConfigurationExportService.makeSupportBundle(
            configuration: configuration,
            diagnostics: nil,
            generatedAt: export.exportedAt,
            appIdentifier: "dev.clange.ssh-autotunnel"
        )
        let validation = ConfigurationExportService.validationReport(for: export, preservingLocalValuesFrom: configuration)
        let response = ControlResponse(
            ok: true,
            message: "Support bundle",
            configurationExport: export,
            supportBundle: bundle,
            configurationValidation: validation
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)

        XCTAssertEqual(decoded.configurationExport, export)
        XCTAssertEqual(decoded.supportBundle, bundle)
        XCTAssertEqual(decoded.configurationValidation, validation)
    }
}
