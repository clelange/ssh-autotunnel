import Foundation

public enum ProfileConfigurationEditorError: LocalizedError, Equatable, Sendable {
    case missingProfilePayload
    case profileNotFound
    case duplicateProfileID(UUID)
    case invalidProfileOrder(String)

    public var errorDescription: String? {
        switch self {
        case .missingProfilePayload:
            "A profile payload is required."
        case .profileNotFound:
            "Profile not found."
        case .duplicateProfileID(let id):
            "A profile with id \(id.uuidString) already exists."
        case .invalidProfileOrder(let reason):
            "Invalid profile order: \(reason)"
        }
    }
}

public enum ProfileConfigurationEditor {
    public static func create(profile: TunnelProfile, in configuration: AppConfiguration) throws -> AppConfiguration {
        try ConfigurationContentValidator.validate(profile: profile)
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
        try ConfigurationContentValidator.validate(profile: profile)

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

    public static func reorderProfiles(profileIDs: [UUID], in configuration: AppConfiguration) throws -> AppConfiguration {
        let existingIDs = configuration.profiles.map(\.id)
        let existingIDSet = Set(existingIDs)
        guard existingIDSet.count == existingIDs.count else {
            throw ProfileConfigurationEditorError.invalidProfileOrder("configuration contains duplicate profile ids")
        }

        var seenIDs = Set<UUID>()
        for id in profileIDs {
            guard seenIDs.insert(id).inserted else {
                throw ProfileConfigurationEditorError.invalidProfileOrder("duplicate profile id \(id.uuidString)")
            }
        }

        let requestedIDSet = Set(profileIDs)
        if let unknownID = requestedIDSet.subtracting(existingIDSet).sorted(by: uuidSort).first {
            throw ProfileConfigurationEditorError.invalidProfileOrder("unknown profile id \(unknownID.uuidString)")
        }
        if let missingID = existingIDSet.subtracting(requestedIDSet).sorted(by: uuidSort).first {
            throw ProfileConfigurationEditorError.invalidProfileOrder("missing profile id \(missingID.uuidString)")
        }

        let profilesByID = Dictionary(uniqueKeysWithValues: configuration.profiles.map { ($0.id, $0) })
        var updated = configuration
        updated.profiles = profileIDs.compactMap { profilesByID[$0] }
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

    private static func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}
