import Foundation

public enum NetworkRuleConfigurationEditorError: LocalizedError, Equatable, Sendable {
    case missingRulePayload
    case ruleNotFound
    case duplicateRuleID(UUID)
    case missingProfile(UUID)

    public var errorDescription: String? {
        switch self {
        case .missingRulePayload:
            "A network rule payload is required."
        case .ruleNotFound:
            "Network rule not found."
        case .duplicateRuleID(let id):
            "A network rule with id \(id.uuidString) already exists."
        case .missingProfile(let id):
            "Network rule references missing profile \(id.uuidString)."
        }
    }
}

public enum NetworkRuleConfigurationEditor {
    public static func create(rule: NetworkPolicyRule, in configuration: AppConfiguration) throws -> AppConfiguration {
        try ConfigurationContentValidator.validate(networkRule: rule)
        guard !configuration.networkRules.contains(where: { $0.id == rule.id }) else {
            throw NetworkRuleConfigurationEditorError.duplicateRuleID(rule.id)
        }
        try validateProfileReference(rule.profileID, in: configuration)

        var updated = configuration
        updated.networkRules.append(rule)
        return updated
    }

    public static func update(
        rule: NetworkPolicyRule,
        matchingID ruleID: UUID? = nil,
        matchingName ruleName: String? = nil,
        in configuration: AppConfiguration
    ) throws -> AppConfiguration {
        guard let index = ruleIndex(id: ruleID ?? rule.id, name: ruleName, in: configuration) else {
            throw NetworkRuleConfigurationEditorError.ruleNotFound
        }
        try ConfigurationContentValidator.validate(networkRule: rule)
        try validateProfileReference(rule.profileID, in: configuration)

        var updated = configuration
        var replacement = rule
        replacement.id = updated.networkRules[index].id
        updated.networkRules[index] = replacement
        return updated
    }

    public static func delete(
        ruleID: UUID? = nil,
        ruleName: String? = nil,
        in configuration: AppConfiguration
    ) throws -> AppConfiguration {
        guard let index = ruleIndex(id: ruleID, name: ruleName, in: configuration) else {
            throw NetworkRuleConfigurationEditorError.ruleNotFound
        }

        var updated = configuration
        updated.networkRules.remove(at: index)
        return updated
    }

    private static func validateProfileReference(_ profileID: UUID?, in configuration: AppConfiguration) throws {
        guard let profileID else { return }
        guard configuration.profiles.contains(where: { $0.id == profileID }) else {
            throw NetworkRuleConfigurationEditorError.missingProfile(profileID)
        }
    }

    private static func ruleIndex(id: UUID?, name: String?, in configuration: AppConfiguration) -> Int? {
        if let id, let index = configuration.networkRules.firstIndex(where: { $0.id == id }) {
            return index
        }
        if let name {
            return configuration.networkRules.firstIndex { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        return nil
    }
}
