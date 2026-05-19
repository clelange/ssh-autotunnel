import Foundation

public enum PACRuleConfigurationEditorError: LocalizedError, Equatable, Sendable {
    case missingRulePayload
    case ruleNotFound
    case duplicateRuleID(UUID)
    case missingProfile(UUID)

    public var errorDescription: String? {
        switch self {
        case .missingRulePayload:
            "A PAC rule payload is required."
        case .ruleNotFound:
            "PAC rule not found."
        case .duplicateRuleID(let id):
            "A PAC rule with id \(id.uuidString) already exists."
        case .missingProfile(let id):
            "PAC rule references missing profile \(id.uuidString)."
        }
    }
}

public enum PACRuleConfigurationEditor {
    public static func create(rule: PACRule, in configuration: AppConfiguration) throws -> AppConfiguration {
        guard !configuration.pacRules.contains(where: { $0.id == rule.id }) else {
            throw PACRuleConfigurationEditorError.duplicateRuleID(rule.id)
        }
        try validateProfileReference(rule.profileID, in: configuration)

        var updated = configuration
        updated.pacRules.append(rule)
        return updated
    }

    public static func update(
        rule: PACRule,
        matchingID ruleID: UUID? = nil,
        matchingName ruleName: String? = nil,
        in configuration: AppConfiguration
    ) throws -> AppConfiguration {
        guard let index = ruleIndex(id: ruleID ?? rule.id, name: ruleName, in: configuration) else {
            throw PACRuleConfigurationEditorError.ruleNotFound
        }
        try validateProfileReference(rule.profileID, in: configuration)

        var updated = configuration
        var replacement = rule
        replacement.id = updated.pacRules[index].id
        updated.pacRules[index] = replacement
        return updated
    }

    public static func delete(
        ruleID: UUID? = nil,
        ruleName: String? = nil,
        in configuration: AppConfiguration
    ) throws -> AppConfiguration {
        guard let index = ruleIndex(id: ruleID, name: ruleName, in: configuration) else {
            throw PACRuleConfigurationEditorError.ruleNotFound
        }

        var updated = configuration
        updated.pacRules.remove(at: index)
        return updated
    }

    private static func validateProfileReference(_ profileID: UUID, in configuration: AppConfiguration) throws {
        guard configuration.profiles.contains(where: { $0.id == profileID }) else {
            throw PACRuleConfigurationEditorError.missingProfile(profileID)
        }
    }

    private static func ruleIndex(id: UUID?, name: String?, in configuration: AppConfiguration) -> Int? {
        if let id, let index = configuration.pacRules.firstIndex(where: { $0.id == id }) {
            return index
        }
        if let name {
            return configuration.pacRules.firstIndex { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        return nil
    }
}
