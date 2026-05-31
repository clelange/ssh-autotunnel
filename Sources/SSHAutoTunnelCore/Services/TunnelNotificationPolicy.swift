import Foundation

public enum ConnectionKind: String, Codable, Equatable, Sendable {
    case tunnel
    case hop
}

public enum TunnelNotificationEvent: Equatable, Sendable {
    case tunnelFailed
    case tunnelRecovered
    case hopFailed
    case hopRecovered

    public var title: String {
        switch self {
        case .tunnelFailed: "Tunnel problem"
        case .tunnelRecovered: "Tunnel recovered"
        case .hopFailed: "Hop connection problem"
        case .hopRecovered: "Hop connection recovered"
        }
    }

    public var kind: ConnectionKind {
        switch self {
        case .tunnelFailed, .tunnelRecovered:
            .tunnel
        case .hopFailed, .hopRecovered:
            .hop
        }
    }

    public var isFailure: Bool {
        switch self {
        case .tunnelFailed, .hopFailed:
            true
        case .tunnelRecovered, .hopRecovered:
            false
        }
    }
}

public enum TunnelNotificationPolicy {
    public static func event(previous: TunnelHealth?, current: TunnelHealth) -> TunnelNotificationEvent? {
        event(previous: previous, current: current, kind: .tunnel)
    }

    public static func event(previous: TunnelHealth?, current: TunnelHealth, kind: ConnectionKind) -> TunnelNotificationEvent? {
        guard previous != current else { return nil }

        if current == .unhealthy || current == .failed {
            switch kind {
            case .tunnel: return .tunnelFailed
            case .hop: return .hopFailed
            }
        }

        if current == .healthy, previous == .unhealthy || previous == .failed || previous == .reconnecting {
            switch kind {
            case .tunnel: return .tunnelRecovered
            case .hop: return .hopRecovered
            }
        }

        return nil
    }
}
