import Foundation

public enum TunnelLifecyclePolicy {
    public enum ProcessExitDecision: Equatable, Sendable {
        case ignore
        case markStopped
        case markFailed
        case reconnect
    }

    public enum HealthProbeFailureDecision: Equatable, Sendable {
        case waitForInitialReadiness
        case markUnhealthy
        case reconnect
    }

    public static func processExitDecision(
        terminationStatus: Int32,
        wasIntentionalStop: Bool,
        autoReconnect: Bool
    ) -> ProcessExitDecision {
        if wasIntentionalStop {
            return .ignore
        }
        if autoReconnect {
            return .reconnect
        }
        return terminationStatus == 0 ? .markStopped : .markFailed
    }

    public static func healthProbeFailureDecision(
        previousHealth: TunnelHealth?,
        autoReconnect: Bool,
        hasInitialReadinessGraceExpired: Bool = true
    ) -> HealthProbeFailureDecision {
        if (previousHealth == .connecting || previousHealth == .reconnecting) && !hasInitialReadinessGraceExpired {
            return .waitForInitialReadiness
        }
        if previousHealth == .unhealthy, autoReconnect {
            return .reconnect
        }
        return .markUnhealthy
    }

    public static func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 1 }
        return min(pow(2.0, Double(attempt - 1)), 30)
    }
}
