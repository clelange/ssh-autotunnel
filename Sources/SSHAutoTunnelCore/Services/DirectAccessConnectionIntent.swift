import Foundation

public struct DirectAccessTransition: Equatable, Sendable {
    public var profileIDsToPause: Set<UUID>
    public var tunnelProfileIDsToResume: Set<UUID>
    public var standaloneHopProfileIDsToResume: Set<UUID>

    public init(
        profileIDsToPause: Set<UUID> = [],
        tunnelProfileIDsToResume: Set<UUID> = [],
        standaloneHopProfileIDsToResume: Set<UUID> = []
    ) {
        self.profileIDsToPause = profileIDsToPause
        self.tunnelProfileIDsToResume = tunnelProfileIDsToResume
        self.standaloneHopProfileIDsToResume = standaloneHopProfileIDsToResume
    }
}

public struct DirectAccessConnectionIntent: Equatable, Sendable {
    public private(set) var desiredTunnelProfileIDs: Set<UUID>
    public private(set) var desiredStandaloneHopProfileIDs: Set<UUID>
    public private(set) var pausedProfileIDs: Set<UUID>

    public init(
        desiredTunnelProfileIDs: Set<UUID> = [],
        desiredStandaloneHopProfileIDs: Set<UUID> = [],
        pausedProfileIDs: Set<UUID> = []
    ) {
        self.desiredTunnelProfileIDs = desiredTunnelProfileIDs
        self.desiredStandaloneHopProfileIDs = desiredStandaloneHopProfileIDs
        self.pausedProfileIDs = pausedProfileIDs
    }

    public func isPaused(_ profileID: UUID) -> Bool {
        pausedProfileIDs.contains(profileID)
    }

    public func shouldResumeTunnel(_ profileID: UUID) -> Bool {
        desiredTunnelProfileIDs.contains(profileID)
    }

    public mutating func requestTunnel(_ profileID: UUID) -> Bool {
        guard !isPaused(profileID) else { return false }
        desiredTunnelProfileIDs.insert(profileID)
        return true
    }

    public mutating func deferTunnelUntilDirectAccessEnds(_ profileID: UUID) {
        desiredTunnelProfileIDs.insert(profileID)
    }

    public mutating func cancelTunnel(_ profileID: UUID) {
        desiredTunnelProfileIDs.remove(profileID)
    }

    public mutating func requestStandaloneHop(_ profileID: UUID) -> Bool {
        guard !isPaused(profileID) else { return false }
        desiredStandaloneHopProfileIDs.insert(profileID)
        return true
    }

    public mutating func deferStandaloneHopUntilDirectAccessEnds(_ profileID: UUID) {
        desiredStandaloneHopProfileIDs.insert(profileID)
    }

    public mutating func cancelStandaloneHop(_ profileID: UUID) {
        desiredStandaloneHopProfileIDs.remove(profileID)
    }

    public mutating func removeProfiles(_ profileIDs: Set<UUID>) {
        desiredTunnelProfileIDs.subtract(profileIDs)
        desiredStandaloneHopProfileIDs.subtract(profileIDs)
        pausedProfileIDs.subtract(profileIDs)
    }

    public mutating func updatePausedProfileIDs(_ newPausedProfileIDs: Set<UUID>) -> DirectAccessTransition {
        let newlyPaused = newPausedProfileIDs.subtracting(pausedProfileIDs)
        let noLongerPaused = pausedProfileIDs.subtracting(newPausedProfileIDs)
        pausedProfileIDs = newPausedProfileIDs

        let tunnelsToResume = noLongerPaused.intersection(desiredTunnelProfileIDs)
        let standaloneHopsToResume = noLongerPaused
            .intersection(desiredStandaloneHopProfileIDs)
            .subtracting(tunnelsToResume)

        return DirectAccessTransition(
            profileIDsToPause: newlyPaused,
            tunnelProfileIDsToResume: tunnelsToResume,
            standaloneHopProfileIDsToResume: standaloneHopsToResume
        )
    }
}
