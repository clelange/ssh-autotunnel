import Foundation

public enum ProfileConfigurationEditorError: LocalizedError, Equatable, Sendable {
    case missingProfilePayload
    case profileNotFound
    case duplicateProfileID(UUID)

    public var errorDescription: String? {
        switch self {
        case .missingProfilePayload:
            "A profile payload is required."
        case .profileNotFound:
            "Profile not found."
        case .duplicateProfileID(let id):
            "A profile with id \(id.uuidString) already exists."
        }
    }
}

public enum ProfileConfigurationEditor {
    public static func create(profile: TunnelProfile, in configuration: AppConfiguration) throws -> AppConfiguration {
        guard !configuration.profiles.contains(where: { $0.id == profile.id }) else {
            throw ProfileConfigurationEditorError.duplicateProfileID(profile.id)
        }

        var updated = configuration
        updated.profiles.append(profile)
        try PortConfigurationValidator.validate(updated)
        return updated
    }

    public static func update(
        profile: TunnelProfile,
        matchingID profileID: UUID? = nil,
        matchingName profileName: String? = nil,
        in configuration: AppConfiguration
    ) throws -> AppConfiguration {
        guard let index = profileIndex(id: profileID ?? profile.id, name: profileName, in: configuration) else {
            throw ProfileConfigurationEditorError.profileNotFound
        }

        var updated = configuration
        var replacement = profile
        replacement.id = updated.profiles[index].id
        updated.profiles[index] = replacement
        rewriteReferences(from: profile.id, to: replacement.id, in: &updated)
        try PortConfigurationValidator.validate(updated)
        return updated
    }

    public static func delete(
        profileID: UUID? = nil,
        profileName: String? = nil,
        in configuration: AppConfiguration
    ) throws -> AppConfiguration {
        guard let index = profileIndex(id: profileID, name: profileName, in: configuration) else {
            throw ProfileConfigurationEditorError.profileNotFound
        }

        let removedID = configuration.profiles[index].id
        var updated = configuration
        updated.profiles.remove(at: index)
        updated.pacRules.removeAll { $0.profileID == removedID }
        updated.networkRules.removeAll { $0.profileID == removedID }
        try PortConfigurationValidator.validate(updated)
        return updated
    }

    private static func profileIndex(id: UUID?, name: String?, in configuration: AppConfiguration) -> Int? {
        if let id, let index = configuration.profiles.firstIndex(where: { $0.id == id }) {
            return index
        }
        if let name {
            return configuration.profiles.firstIndex { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        return nil
    }

    private static func rewriteReferences(from sourceID: UUID, to targetID: UUID, in configuration: inout AppConfiguration) {
        guard sourceID != targetID else { return }
        for index in configuration.pacRules.indices where configuration.pacRules[index].profileID == sourceID {
            configuration.pacRules[index].profileID = targetID
        }
        for index in configuration.networkRules.indices where configuration.networkRules[index].profileID == sourceID {
            configuration.networkRules[index].profileID = targetID
        }
    }
}
