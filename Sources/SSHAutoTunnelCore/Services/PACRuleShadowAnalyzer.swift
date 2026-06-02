import Foundation

public struct PACRuleShadowWarning: Equatable, Sendable {
    public var ruleID: UUID
    public var shadowingRuleID: UUID
    public var shadowingRuleName: String

    public init(ruleID: UUID, shadowingRuleID: UUID, shadowingRuleName: String) {
        self.ruleID = ruleID
        self.shadowingRuleID = shadowingRuleID
        self.shadowingRuleName = shadowingRuleName
    }
}

public enum PACRuleShadowAnalyzer {
    public static func warnings(configuration: AppConfiguration) -> [PACRuleShadowWarning] {
        warnings(
            rules: configuration.pacRules,
            validProfileIDs: Set(configuration.profiles.map(\.id))
        )
    }

    public static func warnings(rules: [PACRule], validProfileIDs: Set<UUID>) -> [PACRuleShadowWarning] {
        var warnings: [PACRuleShadowWarning] = []
        var earlierRules: [PACRule] = []

        for rule in rules {
            guard rule.enabled, validProfileIDs.contains(rule.profileID), !normalized(rule.domainPattern).isEmpty else {
                continue
            }

            if let shadowingRule = earlierRules.first(where: { pattern($0.domainPattern, covers: rule.domainPattern) }) {
                warnings.append(PACRuleShadowWarning(
                    ruleID: rule.id,
                    shadowingRuleID: shadowingRule.id,
                    shadowingRuleName: shadowingRule.name
                ))
            }

            earlierRules.append(rule)
        }

        return warnings
    }

    private static func pattern(_ earlier: String, covers later: String) -> Bool {
        let earlier = normalized(earlier)
        let later = normalized(later)

        guard !earlier.isEmpty, !later.isEmpty else { return false }
        if earlier == "*" || earlier == later { return true }

        if let earlierSuffix = wildcardSubdomainSuffix(earlier) {
            if let laterSuffix = wildcardSubdomainSuffix(later) {
                return laterSuffix.hasSuffix(earlierSuffix) && laterSuffix.count > earlierSuffix.count
            }

            if !later.contains("*") {
                return DomainPattern.matches(host: later, pattern: earlier)
            }
        }

        return false
    }

    private static func wildcardSubdomainSuffix(_ pattern: String) -> String? {
        guard pattern.hasPrefix("*."), pattern.dropFirst(2).contains("*") == false else {
            return nil
        }
        return String(pattern.dropFirst(1))
    }

    private static func normalized(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
