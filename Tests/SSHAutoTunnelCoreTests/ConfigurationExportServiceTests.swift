import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class ConfigurationExportServiceTests: XCTestCase {
    func testConfigurationExportOmitsLocalAPIToken() throws {
        let configuration = sampleConfiguration(apiToken: "secret-local-token")

        let export = ConfigurationExportService.makeExport(
            from: configuration,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appIdentifier: "test.app"
        )
        let data = try JSONEncoder().encode(export)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["apiToken"])
        XCTAssertFalse(json.contains("secret-local-token"))
        XCTAssertEqual(export.redaction.omittedFields, ["apiToken"])
        XCTAssertEqual(export.profiles, configuration.profiles)
        XCTAssertEqual(export.pacRules, configuration.pacRules)
        XCTAssertEqual(export.networkRules, configuration.networkRules)
        XCTAssertEqual(export.pacAppendSource, configuration.pacAppendSource)
    }

    func testDecodeExportDocumentAcceptsRawAppConfigurationBackups() throws {
        let configuration = sampleConfiguration(apiToken: "secret-local-token")
        let data = try JSONEncoder().encode(configuration)

        let export = try ConfigurationExportService.decodeExportDocument(
            from: data,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_004),
            appIdentifier: "test.app"
        )
        let exportedData = try JSONEncoder().encode(export)
        let exportedJSON = try XCTUnwrap(String(data: exportedData, encoding: .utf8))

        XCTAssertEqual(export.profiles, configuration.profiles)
        XCTAssertEqual(export.pacRules, configuration.pacRules)
        XCTAssertEqual(export.networkRules, configuration.networkRules)
        XCTAssertEqual(export.apiHTTPPort, configuration.apiHTTPPort)
        XCTAssertEqual(export.pacAppendSource, configuration.pacAppendSource)
        XCTAssertFalse(exportedJSON.contains("secret-local-token"))
    }

    func testImportPreservesLocalAPIToken() throws {
        let current = AppConfiguration(apiToken: "local-token")
        var source = sampleConfiguration(apiToken: "source-token")
        source.pacAppendSource = PACAppendSource(
            enabled: true,
            kind: .url,
            location: "https://proxy.example/proxy.pac"
        )
        let export = ConfigurationExportService.makeExport(from: source, appIdentifier: "test.app")

        let imported = try ConfigurationExportService.importConfiguration(from: export, preservingLocalValuesFrom: current)

        XCTAssertEqual(imported.apiToken, "local-token")
        XCTAssertEqual(imported.profiles, source.profiles)
        XCTAssertEqual(imported.pacRules, source.pacRules)
        XCTAssertEqual(imported.networkRules, source.networkRules)
        XCTAssertEqual(imported.pacHTTPPort, source.pacHTTPPort)
        XCTAssertEqual(imported.blockingHTTPProxyPort, source.blockingHTTPProxyPort)
        XCTAssertEqual(imported.apiHTTPPort, source.apiHTTPPort)
        XCTAssertEqual(imported.proxyApplyMode, source.proxyApplyMode)
        XCTAssertEqual(imported.pacAppendSource, source.pacAppendSource)
    }

    func testDecodesLegacyExportWithoutPACAppendSource() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "exportedAt": 0,
          "appIdentifier": "test.app",
          "profiles": [],
          "pacRules": [],
          "networkRules": [],
          "pacHTTPPort": 18483,
          "blockingHTTPProxyPort": 18485,
          "apiHTTPPort": 18484,
          "proxyApplyMode": "manual"
        }
        """.utf8)

        let export = try JSONDecoder().decode(ConfigurationExport.self, from: json)

        XCTAssertEqual(export.pacAppendSource, PACAppendSource())
    }

    func testImportRejectsInvalidPorts() throws {
        var export = ConfigurationExportService.makeExport(from: sampleConfiguration(), appIdentifier: "test.app")
        export.apiHTTPPort = export.pacHTTPPort

        XCTAssertThrowsError(
            try ConfigurationExportService.importConfiguration(
                from: export,
                preservingLocalValuesFrom: AppConfiguration(apiToken: "local-token")
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Port \(export.apiHTTPPort) is used by"))
        }
    }

    func testImportRejectsPACRuleWithMissingProfile() throws {
        var export = ConfigurationExportService.makeExport(from: sampleConfiguration(), appIdentifier: "test.app")
        let missingID = try XCTUnwrap(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        export.pacRules[0].profileID = missingID

        XCTAssertThrowsError(
            try ConfigurationExportService.importConfiguration(
                from: export,
                preservingLocalValuesFrom: AppConfiguration(apiToken: "local-token")
            )
        ) { error in
            XCTAssertEqual(error as? ConfigurationExportError, .missingPACRuleProfile(missingID))
        }
    }

    func testValidationReportSummarizesValidExport() {
        let export = ConfigurationExportService.makeExport(from: sampleConfiguration(), appIdentifier: "test.app")

        let report = ConfigurationExportService.validationReport(
            for: export,
            preservingLocalValuesFrom: AppConfiguration(apiToken: "local-token")
        )

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.message, "Configuration export is valid")
        XCTAssertEqual(report.messages, [])
        XCTAssertEqual(report.profileCount, 1)
        XCTAssertEqual(report.pacRuleCount, 1)
        XCTAssertEqual(report.networkRuleCount, 1)
    }

    func testValidationReportCollectsPortMessages() {
        var export = ConfigurationExportService.makeExport(from: sampleConfiguration(), appIdentifier: "test.app")
        export.blockingHTTPProxyPort = export.pacHTTPPort

        let report = ConfigurationExportService.validationReport(
            for: export,
            preservingLocalValuesFrom: AppConfiguration(apiToken: "local-token")
        )

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.messages, ["Port \(export.pacHTTPPort) is used by PAC HTTP port, Blocking proxy port"])
    }

    func testSupportBundleIncludesRedactedConfigurationAndDiagnostics() throws {
        let configuration = sampleConfiguration(apiToken: "secret-local-token")
        let diagnostics = DiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            appIdentifier: "test.app",
            pacURL: "http://127.0.0.1:18483/proxy.pac",
            statusURL: "http://127.0.0.1:18483/status",
            proxyApplyMode: configuration.proxyApplyMode,
            proxyDisabledByNetworkPolicy: false,
            matchedNetworkRule: nil,
            configuredPorts: LocalServerPorts(configuration: configuration),
            activePorts: nil,
            currentNetwork: NetworkFingerprint(serviceName: "Wi-Fi"),
            profiles: [],
            fileStatuses: [],
            systemProxySnapshotExists: false
        )

        let bundle = ConfigurationExportService.makeSupportBundle(
            configuration: configuration,
            diagnostics: diagnostics,
            generatedAt: diagnostics.generatedAt,
            appIdentifier: "test.app"
        )
        let data = try JSONEncoder().encode(bundle)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exportedConfiguration = try XCTUnwrap(object["configuration"] as? [String: Any])

        XCTAssertEqual(bundle.configuration.profiles, configuration.profiles)
        XCTAssertEqual(bundle.diagnostics, diagnostics)
        XCTAssertNil(exportedConfiguration["apiToken"])
        XCTAssertFalse(json.contains("secret-local-token"))
    }

    func testSupportBundleRedactsHomeDirectoryPathsInDiagnostics() throws {
        let configuration = sampleConfiguration()
        let diagnostics = DiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_003),
            appIdentifier: "test.app",
            pacURL: "http://127.0.0.1:18483/proxy.pac",
            statusURL: "http://127.0.0.1:18483/status",
            proxyApplyMode: configuration.proxyApplyMode,
            proxyDisabledByNetworkPolicy: false,
            matchedNetworkRule: nil,
            configuredPorts: LocalServerPorts(configuration: configuration),
            activePorts: nil,
            currentNetwork: NetworkFingerprint(),
            profiles: [],
            fileStatuses: [
                DiagnosticFileStatus(
                    label: "Configuration",
                    path: "/Users/alice/Library/Application Support/SSHAutoTunnel/config.json",
                    exists: true,
                    posixPermissions: "600",
                    isPrivate: true
                )
            ],
            systemProxySnapshotExists: false
        )

        let bundle = ConfigurationExportService.makeSupportBundle(
            configuration: configuration,
            diagnostics: diagnostics,
            generatedAt: diagnostics.generatedAt,
            appIdentifier: "test.app",
            homeDirectoryPath: "/Users/alice"
        )

        XCTAssertEqual(
            bundle.diagnostics?.fileStatuses.first?.path,
            "~/Library/Application Support/SSHAutoTunnel/config.json"
        )
    }

    private func sampleConfiguration(apiToken: String = "token") -> AppConfiguration {
        let profileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let pacRuleID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let networkRuleID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let profile = TunnelProfile(
            id: profileID,
            name: "CERN lxplus",
            host: "lxplus.cern.ch",
            localSocksPort: 1081,
            authMode: .kerberosAndTOTP,
            keychain: KeychainReference(account: "user", totpService: "cern-lxplus-otp-secret")
        )
        return AppConfiguration(
            profiles: [profile],
            pacRules: [
                PACRule(
                    id: pacRuleID,
                    name: "CERN",
                    domainPattern: "*.cern.ch",
                    profileID: profileID
                )
            ],
            networkRules: [
                NetworkPolicyRule(
                    id: networkRuleID,
                    name: "CERN trusted network",
                    match: NetworkMatch(searchDomainContains: "cern.ch"),
                    action: .disableProxy,
                    profileID: profileID
                )
            ],
            pacHTTPPort: 18483,
            blockingHTTPProxyPort: 18485,
            apiHTTPPort: 18484,
            apiToken: apiToken,
            proxyApplyMode: .activeNetworkServicePAC
        )
    }
}
