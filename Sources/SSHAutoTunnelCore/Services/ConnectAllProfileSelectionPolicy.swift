import Foundation

public enum ConnectAllProfileSelectionPolicy {
    public static func profilesToConnect(
        from profiles: [TunnelProfile],
        healthByProfileID: [UUID: TunnelHealth]
    ) -> [TunnelProfile] {
        profiles.filter { profile in
            profile.includeInConnectAll && !isActive(healthByProfileID[profile.id] ?? .stopped)
        }
    }

    private static func isActive(_ health: TunnelHealth) -> Bool {
        switch health {
        case .healthy, .connecting, .stopping, .degraded, .reconnecting:
            true
        case .stopped, .unhealthy, .failed:
            false
        }
    }
}
