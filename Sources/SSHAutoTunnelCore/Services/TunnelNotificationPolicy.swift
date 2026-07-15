import Foundation

public enum ConnectionKind: String, Codable, Equatable, Sendable {
    case tunnel
    case hop
}

public enum TunnelNotificationEvent: Equatable, Sendable {
    case tunnelInterrupted
    case tunnelReconnectStopped
    case tunnelFailed
    case tunnelRecovered
    case hopInterrupted
    case hopReconnectStopped
    case hopFailed
    case hopRecovered

    public var title: String {
        switch self {
        case .tunnelInterrupted: "Tunnel interrupted"
        case .tunnelReconnectStopped: "Automatic tunnel reconnect stopped"
        case .tunnelFailed: "Tunnel problem"
        case .tunnelRecovered: "Tunnel recovered"
        case .hopInterrupted: "Hop connection interrupted"
        case .hopReconnectStopped: "Automatic hop reconnect stopped"
        case .hopFailed: "Hop connection problem"
        case .hopRecovered: "Hop connection recovered"
        }
    }

    public var kind: ConnectionKind {
        switch self {
        case .tunnelInterrupted, .tunnelReconnectStopped, .tunnelFailed, .tunnelRecovered:
            .tunnel
        case .hopInterrupted, .hopReconnectStopped, .hopFailed, .hopRecovered:
            .hop
        }
    }

    public var isFailure: Bool {
        switch self {
        case .tunnelReconnectStopped, .tunnelFailed, .hopReconnectStopped, .hopFailed:
            true
        case .tunnelInterrupted, .tunnelRecovered, .hopInterrupted, .hopRecovered:
            false
        }
    }

    public var offersTryAgainAction: Bool {
        isFailure
    }
}

public enum TunnelNotificationPolicy {
    public static func event(previous: TunnelHealth?, current: TunnelHealth) -> TunnelNotificationEvent? {
        event(previous: previous, current: current, kind: .tunnel)
    }

    public static func event(previous: TunnelHealth?, current: TunnelHealth, kind: ConnectionKind) -> TunnelNotificationEvent? {
        guard previous != current else { return nil }

        if current == .reconnecting, previous == .healthy || previous == .degraded {
            switch kind {
            case .tunnel: return .tunnelInterrupted
            case .hop: return .hopInterrupted
            }
        }

        if current == .unhealthy, previous == .healthy || previous == .degraded {
            switch kind {
            case .tunnel: return .tunnelInterrupted
            case .hop: return .hopInterrupted
            }
        }

        if current == .failed, previous == .reconnecting {
            switch kind {
            case .tunnel: return .tunnelReconnectStopped
            case .hop: return .hopReconnectStopped
            }
        }

        if current == .unhealthy || current == .failed {
            switch kind {
            case .tunnel: return .tunnelFailed
            case .hop: return .hopFailed
            }
        }

        if current == .reconnecting, previous == .unhealthy {
            return nil
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
