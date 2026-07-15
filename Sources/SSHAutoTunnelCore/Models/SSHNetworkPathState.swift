import Foundation

public enum SSHNetworkPathState: String, Codable, Equatable, Sendable {
    case unknown
    case unsatisfied
    case requiresConnection
    case satisfied

    public var permitsSSHLaunch: Bool {
        self == .satisfied
    }

    public var displayName: String {
        switch self {
        case .unknown:
            "Unknown"
        case .unsatisfied:
            "Unavailable"
        case .requiresConnection:
            "Connection required"
        case .satisfied:
            "Available"
        }
    }
}

public enum SSHNetworkLaunchPolicy {
    public static let stabilizationInterval = TunnelLifecyclePolicy.networkStabilizationInterval

    public static func permitsLaunch(for pathState: SSHNetworkPathState) -> Bool {
        pathState.permitsSSHLaunch
    }
}
