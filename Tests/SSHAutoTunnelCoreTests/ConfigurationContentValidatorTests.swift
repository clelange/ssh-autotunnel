import XCTest
@testable import SSHAutoTunnelCore

final class ConfigurationContentValidatorTests: XCTestCase {
    func testProfileEditorRejectsControlCharactersInProfileFields() {
        let profile = TunnelProfile(
            name: "Bad\nProfile",
            host: "ssh.example.org",
            localSocksPort: 1200,
            keychain: KeychainReference(account: "alice")
        )

        XCTAssertThrowsError(try ProfileConfigurationEditor.create(profile: profile, in: AppConfiguration())) { error in
            let validationError = error as? ConfigurationContentValidationError
            XCTAssertTrue(validationError?.messages.contains("Profile 'Bad\nProfile' name contains a control character or newline") == true)
        }
    }

    func testProfileEditorRejectsControlCharactersInKeychainReferences() {
        let profile = TunnelProfile(
            name: "Bad Keychain",
            host: "ssh.example.org",
            localSocksPort: 1200,
            keychain: KeychainReference(account: "alice", passwordService: "password\nservice")
        )

        XCTAssertThrowsError(try ProfileConfigurationEditor.create(profile: profile, in: AppConfiguration())) { error in
            let validationError = error as? ConfigurationContentValidationError
            XCTAssertTrue(validationError?.messages.contains("Profile 'Bad Keychain' password Keychain service contains a control character or newline") == true)
        }
    }

    func testPACRuleEditorRejectsControlCharactersInDomainPattern() {
        let profile = TunnelProfile(name: "Profile", host: "ssh.example.org", localSocksPort: 1200)
        let rule = PACRule(name: "Bad PAC", domainPattern: "*.example.org\nreturn \"DIRECT\";", profileID: profile.id)

        XCTAssertThrowsError(try PACRuleConfigurationEditor.create(rule: rule, in: AppConfiguration(profiles: [profile]))) { error in
            let validationError = error as? ConfigurationContentValidationError
            XCTAssertTrue(validationError?.messages.contains("PAC rule 'Bad PAC' domain pattern contains a control character or newline") == true)
        }
    }

    func testNetworkRuleEditorRejectsEmptyNetworkMatch() {
        let rule = NetworkPolicyRule(name: "Global by accident", match: NetworkMatch(), action: .disableProxy)

        XCTAssertThrowsError(try NetworkRuleConfigurationEditor.create(rule: rule, in: AppConfiguration())) { error in
            let validationError = error as? ConfigurationContentValidationError
            XCTAssertTrue(validationError?.messages.contains("Network rule 'Global by accident' must define at least one match field") == true)
        }
    }

    func testProfileEditorRejectsConflictingProxyJumpAndProxyCommand() {
        let profile = TunnelProfile(
            name: "Conflict",
            host: "ssh.example.org",
            localSocksPort: 1200,
            jumpHost: "jump.example.org",
            curatedSSHOptions: CuratedSSHOptions(proxyCommand: "ssh jump -W %h:%p")
        )

        XCTAssertThrowsError(try ProfileConfigurationEditor.create(profile: profile, in: AppConfiguration())) { error in
            let validationError = error as? ConfigurationContentValidationError
            XCTAssertTrue(validationError?.messages.contains("Profile 'Conflict' cannot define both ProxyJump and ProxyCommand") == true)
        }
    }

    func testProfileEditorRejectsNegativeReconnectAttemptLimit() {
        let profile = TunnelProfile(
            name: "Reconnect",
            host: "ssh.example.org",
            localSocksPort: 1200,
            curatedSSHOptions: CuratedSSHOptions(maxReconnectAttempts: -1)
        )

        XCTAssertThrowsError(try ProfileConfigurationEditor.create(profile: profile, in: AppConfiguration())) { error in
            let validationError = error as? ConfigurationContentValidationError
            XCTAssertTrue(validationError?.messages.contains("Profile 'Reconnect' reconnect attempt limit must be between 1 and 3") == true)
        }
    }

    func testConfigurationImportRejectsInvalidProfileContent() {
        let profile = TunnelProfile(name: "Bad", host: "ssh.example.org\nProxyCommand echo bad", localSocksPort: 1200)
        let export = ConfigurationExport(
            appIdentifier: "test.app",
            profiles: [profile],
            pacRules: [],
            networkRules: [],
            pacHTTPPort: 18483,
            blockingHTTPProxyPort: 18485,
            apiHTTPPort: 18484,
            proxyApplyMode: .manual
        )

        XCTAssertThrowsError(
            try ConfigurationExportService.importConfiguration(
                from: export,
                preservingLocalValuesFrom: AppConfiguration(apiToken: "local")
            )
        ) { error in
            let validationError = error as? ConfigurationContentValidationError
            XCTAssertTrue(validationError?.messages.contains("Profile 'Bad' host contains a control character or newline") == true)
        }
    }

    func testValidationReportWarnsAboutRiskyExtraSSHOptions() {
        let profile = TunnelProfile(
            name: "Imported",
            host: "ssh.example.org",
            localSocksPort: 1200,
            extraSSHOptions: [
                "-o", "ProxyCommand=nc %h %p",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null"
            ]
        )
        let export = ConfigurationExport(
            appIdentifier: "test.app",
            profiles: [profile],
            pacRules: [],
            networkRules: [],
            pacHTTPPort: 18483,
            blockingHTTPProxyPort: 18485,
            apiHTTPPort: 18484,
            proxyApplyMode: .manual
        )

        let report = ConfigurationExportService.validationReport(
            for: export,
            preservingLocalValuesFrom: AppConfiguration(apiToken: "local")
        )

        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.message, "Configuration export is valid with warnings")
        XCTAssertEqual(report.warnings.count, 3)
        XCTAssertTrue(report.warnings.contains { $0.contains("ProxyCommand") })
        XCTAssertTrue(report.warnings.contains { $0.contains("host-key") })
        XCTAssertTrue(report.warnings.contains { $0.contains("known-host") })
    }
}
