import Foundation

public struct GenericPasswordItemReference: Equatable, Hashable, Sendable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum ProfileKeychainCleanupPlanner {
    public static func removableItems(
        removingProfileID profileID: UUID,
        from configuration: AppConfiguration
    ) -> [GenericPasswordItemReference] {
        removableItems(removingProfileIDs: [profileID], from: configuration)
    }

    public static func removableItems(
        removingProfileIDs profileIDs: Set<UUID>,
        from configuration: AppConfiguration
    ) -> [GenericPasswordItemReference] {
        guard !profileIDs.isEmpty else { return [] }

        let removedProfiles = configuration.profiles.filter { profileIDs.contains($0.id) }
        let remainingProfiles = configuration.profiles.filter { !profileIDs.contains($0.id) }
        let removedItems = Set(removedProfiles.flatMap(itemReferences))
        let remainingItems = Set(remainingProfiles.flatMap(itemReferences))

        return removedItems
            .subtracting(remainingItems)
            .sorted {
                if $0.service == $1.service {
                    return $0.account < $1.account
                }
                return $0.service < $1.service
            }
    }

    private static func itemReferences(for profile: TunnelProfile) -> [GenericPasswordItemReference] {
        [profile.keychain.passwordService, profile.keychain.totpService].compactMap { service in
            guard let service, !service.isEmpty else { return nil }
            return GenericPasswordItemReference(service: service, account: profile.keychain.account)
        }
    }
}
