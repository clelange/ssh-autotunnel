import Foundation

public enum QuitConnectionWarningKind: String, Codable, Equatable, Sendable {
    case tunnel
    case hop
    case interactiveSession
    case untrackedTunnelListener
}

public struct QuitConnectionWarning: Codable, Equatable, Sendable {
    public var kind: QuitConnectionWarningKind
    public var profileName: String
    public var detail: String
    public var isAppOwnedConnection: Bool

    public init(
        kind: QuitConnectionWarningKind,
        profileName: String,
        detail: String,
        isAppOwnedConnection: Bool
    ) {
        self.kind = kind
        self.profileName = profileName
        self.detail = detail
        self.isAppOwnedConnection = isAppOwnedConnection
    }

    public var displayLine: String {
        "\(profileName): \(detail)"
    }
}

public enum QuitConnectionWarningPolicy {
    public static func warnings(
        profiles: [ProfileStatusSnapshot],
        interactiveSessions: [ActiveInteractiveSSHSession],
        socks5Probe: (Int) -> Bool
    ) -> [QuitConnectionWarning] {
        var warnings: [QuitConnectionWarning] = []

        for profile in profiles {
            if isActive(profile.health) {
                warnings.append(
                    QuitConnectionWarning(
                        kind: .tunnel,
                        profileName: profile.name,
                        detail: runtimeDetail(kind: "Tunnel", health: profile.health, pid: profile.pid),
                        isAppOwnedConnection: true
                    )
                )
            } else if socks5Probe(profile.localSocksPort) {
                warnings.append(
                    QuitConnectionWarning(
                        kind: .untrackedTunnelListener,
                        profileName: profile.name,
                        detail: "Untracked SOCKS listener on 127.0.0.1:\(profile.localSocksPort)",
                        isAppOwnedConnection: false
                    )
                )
            }

            if let hop = profile.hop, isActive(hop.health) {
                warnings.append(
                    QuitConnectionWarning(
                        kind: .hop,
                        profileName: profile.name,
                        detail: runtimeDetail(kind: "Hop via \(hop.jumpHost)", health: hop.health, pid: hop.pid),
                        isAppOwnedConnection: true
                    )
                )
            }
        }

        warnings += interactiveSessions.map { session in
            QuitConnectionWarning(
                kind: .interactiveSession,
                profileName: session.profileName,
                detail: "Interactive SSH session via \(session.jumpHost)",
                isAppOwnedConnection: false
            )
        }

        return warnings
    }

    public static func isActive(_ health: TunnelHealth) -> Bool {
        switch health {
        case .connecting, .stopping, .healthy, .degraded, .unhealthy, .reconnecting:
            return true
        case .stopped, .failed:
            return false
        }
    }

    private static func runtimeDetail(kind: String, health: TunnelHealth, pid: Int32?) -> String {
        var detail = "\(kind) \(health.rawValue)"
        if let pid {
            detail += " (pid \(pid))"
        }
        return detail
    }
}
