import XCTest
@testable import SSHAutoTunnelCore

final class NetworkRuleConfigurationEditorTests: XCTestCase {
    func testCreatesGlobalNetworkRule() throws {
        let rule = NetworkPolicyRule(name: "Trusted", match: NetworkMatch(wifiSSID: "Office"), action: .disableProxy)

        let configuration = try NetworkRuleConfigurationEditor.create(rule: rule, in: AppConfiguration())

        XCTAssertEqual(configuration.networkRules, [rule])
    }

    func testCreatesScopedNetworkRuleWhenProfileExists() throws {
        let profile = TunnelProfile(name: "Profile", host: "ssh.example.org", localSocksPort: 1200)
        let rule = NetworkPolicyRule(
            name: "Trusted",
            match: NetworkMatch(searchDomainContains: "example.org"),
            action: .disableProxy,
            profileID: profile.id
        )

        let configuration = try NetworkRuleConfigurationEditor.create(
            rule: rule,
            in: AppConfiguration(profiles: [profile])
        )

        XCTAssertEqual(configuration.networkRules, [rule])
    }

    func testCreateRejectsMissingProfileReference() {
        let rule = NetworkPolicyRule(
            name: "Trusted",
            match: NetworkMatch(wifiSSID: "Office"),
            action: .disableProxy,
            profileID: UUID()
        )

        XCTAssertThrowsError(try NetworkRuleConfigurationEditor.create(rule: rule, in: AppConfiguration())) { error in
            XCTAssertEqual(error as? NetworkRuleConfigurationEditorError, .missingProfile(rule.profileID!))
        }
    }

    func testCreateRejectsDuplicateRuleID() {
        let rule = NetworkRuleTemplate.example()
        let configuration = AppConfiguration(networkRules: [rule])

        XCTAssertThrowsError(try NetworkRuleConfigurationEditor.create(rule: rule, in: configuration)) { error in
            XCTAssertEqual(error as? NetworkRuleConfigurationEditorError, .duplicateRuleID(rule.id))
        }
    }

    func testUpdatesRuleWhilePreservingExistingID() throws {
        let existingID = UUID()
        let incomingID = UUID()
        let existing = NetworkPolicyRule(
            id: existingID,
            name: "Trusted",
            match: NetworkMatch(wifiSSID: "Old"),
            action: .disableProxy
        )
        let incoming = NetworkPolicyRule(
            id: incomingID,
            name: "Trusted",
            enabled: false,
            match: NetworkMatch(wifiSSID: "New"),
            action: .allowProxy
        )
        let configuration = AppConfiguration(networkRules: [existing])

        let updated = try NetworkRuleConfigurationEditor.update(rule: incoming, matchingName: "trusted", in: configuration)

        XCTAssertEqual(updated.networkRules.count, 1)
        XCTAssertEqual(updated.networkRules[0].id, existingID)
        XCTAssertEqual(updated.networkRules[0].match.wifiSSID, "New")
        XCTAssertEqual(updated.networkRules[0].action, .allowProxy)
        XCTAssertFalse(updated.networkRules[0].enabled)
    }

    func testDeleteRemovesRuleByName() throws {
        let keep = NetworkPolicyRule(name: "Keep", match: NetworkMatch(wifiSSID: "Keep"), action: .disableProxy)
        let remove = NetworkPolicyRule(name: "Remove", match: NetworkMatch(wifiSSID: "Remove"), action: .disableProxy)
        let configuration = AppConfiguration(networkRules: [keep, remove])

        let updated = try NetworkRuleConfigurationEditor.delete(ruleName: "remove", in: configuration)

        XCTAssertEqual(updated.networkRules, [keep])
    }

    func testDeleteRequiresExistingRule() {
        XCTAssertThrowsError(try NetworkRuleConfigurationEditor.delete(ruleName: "missing", in: AppConfiguration())) { error in
            XCTAssertEqual(error as? NetworkRuleConfigurationEditorError, .ruleNotFound)
        }
    }
}
