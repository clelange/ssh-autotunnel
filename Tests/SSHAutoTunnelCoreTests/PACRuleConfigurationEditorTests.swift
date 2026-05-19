import XCTest
@testable import SSHAutoTunnelCore

final class PACRuleConfigurationEditorTests: XCTestCase {
    func testCreatesPACRuleWhenProfileExists() throws {
        let profile = TunnelProfile(name: "Profile", host: "ssh.example.org", localSocksPort: 1200)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)

        let configuration = try PACRuleConfigurationEditor.create(
            rule: rule,
            in: AppConfiguration(profiles: [profile])
        )

        XCTAssertEqual(configuration.pacRules, [rule])
    }

    func testCreateRejectsMissingProfileReference() {
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: UUID())

        XCTAssertThrowsError(try PACRuleConfigurationEditor.create(rule: rule, in: AppConfiguration())) { error in
            XCTAssertEqual(error as? PACRuleConfigurationEditorError, .missingProfile(rule.profileID))
        }
    }

    func testCreateRejectsDuplicateRuleID() {
        let profile = TunnelProfile(name: "Profile", host: "ssh.example.org", localSocksPort: 1200)
        let rule = PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)
        let configuration = AppConfiguration(profiles: [profile], pacRules: [rule])

        XCTAssertThrowsError(try PACRuleConfigurationEditor.create(rule: rule, in: configuration)) { error in
            XCTAssertEqual(error as? PACRuleConfigurationEditorError, .duplicateRuleID(rule.id))
        }
    }

    func testUpdatesRuleWhilePreservingExistingID() throws {
        let profile = TunnelProfile(name: "Profile", host: "ssh.example.org", localSocksPort: 1200)
        let existingID = UUID()
        let incomingID = UUID()
        let existing = PACRule(id: existingID, name: "Example", domainPattern: "*.old.example.org", profileID: profile.id)
        let incoming = PACRule(id: incomingID, name: "Example", domainPattern: "*.new.example.org", profileID: profile.id, failureMode: .directFallback)
        let configuration = AppConfiguration(profiles: [profile], pacRules: [existing])

        let updated = try PACRuleConfigurationEditor.update(rule: incoming, matchingName: "example", in: configuration)

        XCTAssertEqual(updated.pacRules.count, 1)
        XCTAssertEqual(updated.pacRules[0].id, existingID)
        XCTAssertEqual(updated.pacRules[0].domainPattern, "*.new.example.org")
        XCTAssertEqual(updated.pacRules[0].failureMode, .directFallback)
    }

    func testDeleteRemovesRuleByName() throws {
        let profile = TunnelProfile(name: "Profile", host: "ssh.example.org", localSocksPort: 1200)
        let keep = PACRule(name: "Keep", domainPattern: "*.keep.example.org", profileID: profile.id)
        let remove = PACRule(name: "Remove", domainPattern: "*.remove.example.org", profileID: profile.id)
        let configuration = AppConfiguration(profiles: [profile], pacRules: [keep, remove])

        let updated = try PACRuleConfigurationEditor.delete(ruleName: "remove", in: configuration)

        XCTAssertEqual(updated.pacRules, [keep])
    }

    func testDeleteRequiresExistingRule() {
        XCTAssertThrowsError(try PACRuleConfigurationEditor.delete(ruleName: "missing", in: AppConfiguration())) { error in
            XCTAssertEqual(error as? PACRuleConfigurationEditorError, .ruleNotFound)
        }
    }
}
