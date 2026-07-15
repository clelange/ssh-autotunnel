import Foundation

public enum TunnelLifecyclePolicy {
    public static let maximumReconnectAttempts = 3
    public static let endpointAttemptLimit = 3
    public static let endpointAttemptWindow: TimeInterval = 10 * 60
    public static let healthyResetInterval: TimeInterval = 5 * 60
    public static let networkStabilizationInterval: TimeInterval = 5

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
        autoReconnect: Bool,
        canAutomaticallyReconnect: Bool = true,
        failureIsRetryable: Bool = true
    ) -> ProcessExitDecision {
        if wasIntentionalStop {
            return .ignore
        }
        if autoReconnect, canAutomaticallyReconnect, failureIsRetryable {
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

    public static func baseReconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 5
        case 2: 30
        default: 120
        }
    }

    public static func reconnectDelay(forAttempt attempt: Int, jitterFraction: Double = 0) -> TimeInterval {
        let clampedJitter = min(max(jitterFraction, 0), 0.2)
        return baseReconnectDelay(forAttempt: attempt) * (1 + clampedJitter)
    }

    public static func effectiveReconnectAttemptLimit(_ configuredLimit: Int?) -> Int {
        min(max(configuredLimit ?? maximumReconnectAttempts, 0), maximumReconnectAttempts)
    }
}
