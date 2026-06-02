import XCTest
@testable import SSHAutoTunnelCore

final class PACRuleShadowAnalyzerTests: XCTestCase {
    func testBroadWildcardShadowsNestedWildcard() {
        let profile = TunnelProfile(name: "CERN", host: "lxtunnel.cern.ch", localSocksPort: 1081)
        let broad = PACRule(name: "CERN", domainPattern: "*.cern.ch", profileID: profile.id)
        let docs = PACRule(name: "CERN Docs", domainPattern: "*.docs.cern.ch", profileID: profile.id)

        let warnings = PACRuleShadowAnalyzer.warnings(configuration: AppConfiguration(
            profiles: [profile],
            pacRules: [broad, docs]
        ))

        XCTAssertEqual(warnings, [
            PACRuleShadowWarning(ruleID: docs.id, shadowingRuleID: broad.id, shadowingRuleName: broad.name)
        ])
    }

    func testNestedWildcardBeforeBroadWildcardIsNotShadowed() {
        let profile = TunnelProfile(name: "CERN", host: "lxtunnel.cern.ch", localSocksPort: 1081)
        let docs = PACRule(name: "CERN Docs", domainPattern: "*.docs.cern.ch", profileID: profile.id)
        let broad = PACRule(name: "CERN", domainPattern: "*.cern.ch", profileID: profile.id)

        let warnings = PACRuleShadowAnalyzer.warnings(configuration: AppConfiguration(
            profiles: [profile],
            pacRules: [docs, broad]
        ))

        XCTAssertTrue(warnings.isEmpty)
    }

    func testIdenticalPatternIsShadowed() {
        let profile = TunnelProfile(name: "Example", host: "ssh.example.org", localSocksPort: 1081)
        let first = PACRule(name: "First", domainPattern: "*.example.org", profileID: profile.id)
        let second = PACRule(name: "Second", domainPattern: "*.example.org", profileID: profile.id)

        let warnings = PACRuleShadowAnalyzer.warnings(configuration: AppConfiguration(
            profiles: [profile],
            pacRules: [first, second]
        ))

        XCTAssertEqual(warnings.first?.ruleID, second.id)
        XCTAssertEqual(warnings.first?.shadowingRuleID, first.id)
    }

    func testCatchAllShadowsLaterRule() {
        let profile = TunnelProfile(name: "Example", host: "ssh.example.org", localSocksPort: 1081)
        let catchAll = PACRule(name: "All", domainPattern: "*", profileID: profile.id)
        let specific = PACRule(name: "Specific", domainPattern: "docs.example.org", profileID: profile.id)

        let warnings = PACRuleShadowAnalyzer.warnings(configuration: AppConfiguration(
            profiles: [profile],
            pacRules: [catchAll, specific]
        ))

        XCTAssertEqual(warnings.first?.ruleID, specific.id)
        XCTAssertEqual(warnings.first?.shadowingRuleName, "All")
    }

    func testDisabledAndMissingProfileRulesAreIgnored() {
        let profile = TunnelProfile(name: "Example", host: "ssh.example.org", localSocksPort: 1081)
        let disabledBroad = PACRule(name: "Disabled", domainPattern: "*.example.org", profileID: profile.id, enabled: false)
        let missingProfileBroad = PACRule(name: "Missing", domainPattern: "*.example.org", profileID: UUID())
        let specific = PACRule(name: "Specific", domainPattern: "*.docs.example.org", profileID: profile.id)

        let warnings = PACRuleShadowAnalyzer.warnings(configuration: AppConfiguration(
            profiles: [profile],
            pacRules: [disabledBroad, missingProfileBroad, specific]
        ))

        XCTAssertTrue(warnings.isEmpty)
    }

    func testComplexGlobDoesNotWarnUnlessIdentical() {
        let profile = TunnelProfile(name: "Example", host: "ssh.example.org", localSocksPort: 1081)
        let complex = PACRule(name: "Complex", domainPattern: "*example.org", profileID: profile.id)
        let nested = PACRule(name: "Nested", domainPattern: "*.docs.example.org", profileID: profile.id)

        let warnings = PACRuleShadowAnalyzer.warnings(configuration: AppConfiguration(
            profiles: [profile],
            pacRules: [complex, nested]
        ))

        XCTAssertTrue(warnings.isEmpty)
    }
}
