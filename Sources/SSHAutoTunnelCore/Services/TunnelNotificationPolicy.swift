import Foundation

public enum TunnelNotificationEvent: Equatable, Sendable {
    case tunnelFailed
    case tunnelRecovered

    public var title: String {
        switch self {
        case .tunnelFailed: "Tunnel problem"
        case .tunnelRecovered: "Tunnel recovered"
        }
    }
}

public enum TunnelNotificationPolicy {
    public static func event(previous: TunnelHealth?, current: TunnelHealth) -> TunnelNotificationEvent? {
        guard previous != current else { return nil }

        if current == .unhealthy || current == .failed {
            return .tunnelFailed
        }

        if current == .healthy, previous == .unhealthy || previous == .failed || previous == .reconnecting {
            return .tunnelRecovered
        }

        return nil
    }
}
