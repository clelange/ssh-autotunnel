import Foundation

public enum ProfileDeletionSelectionPolicy {
    public static func nearestRemainingProfileID(
        afterDeleting deletingIDs: [UUID],
        selectedProfileID: UUID?,
        profiles: [TunnelProfile]
    ) -> UUID? {
        let deletingIDSet = Set(deletingIDs)
        if let selectedProfileID,
           !deletingIDSet.contains(selectedProfileID),
           profiles.contains(where: { $0.id == selectedProfileID }) {
            return selectedProfileID
        }

        let targetIndex = deletingIDs.compactMap { id in
            profiles.firstIndex { $0.id == id }
        }.min()
        let remainingProfiles = profiles.enumerated().filter { !deletingIDSet.contains($0.element.id) }
        guard !remainingProfiles.isEmpty else { return nil }
        guard let targetIndex else { return remainingProfiles.first?.element.id }

        return remainingProfiles.first { $0.offset > targetIndex }?.element.id
            ?? remainingProfiles.last?.element.id
    }
}
