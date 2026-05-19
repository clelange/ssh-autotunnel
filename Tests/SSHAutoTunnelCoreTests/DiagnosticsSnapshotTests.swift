import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class DiagnosticsSnapshotTests: XCTestCase {
    func testDiagnosticsSnapshotRoundTripsThroughJSON() throws {
        let profileID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let profile = TunnelProfile(id: profileID, name: "CERN lxplus", host: "lxplus.cern.ch", localSocksPort: 1081)
        let status = TunnelRuntimeStatus(profileID: profileID, health: .healthy, message: "SOCKS5 OK", pid: 42)
        let snapshot = DiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appIdentifier: "dev.clange.ssh-autotunnel",
            pacURL: "http://127.0.0.1:18483/proxy.pac",
            statusURL: "http://127.0.0.1:18483/status",
            proxyApplyMode: .activeNetworkServicePAC,
            proxyDisabledByNetworkPolicy: true,
            matchedNetworkRule: "Trusted Wi-Fi: CERN",
            configuredPorts: LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484),
            activePorts: LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484),
            currentNetwork: NetworkFingerprint(serviceName: "Wi-Fi", wifiSSID: "CERN", hasVPNInterface: true),
            profiles: [ProfileStatusSnapshot(profile: profile, status: status)],
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
