import Foundation

public enum ReconnectConfigurationMigration {
    public static func migrate(_ configuration: AppConfiguration) -> (configuration: AppConfiguration, didUpdate: Bool) {
        var updated = configuration
        var didUpdate = false

        for index in updated.profiles.indices {
            let configured = updated.profiles[index].curatedSSHOptions.maxReconnectAttempts
            let normalized: Int
            if configured == 0 {
                if updated.profiles[index].autoReconnect {
                    updated.profiles[index].autoReconnect = false
                    didUpdate = true
                }
                normalized = TunnelLifecyclePolicy.maximumReconnectAttempts
            } else if let configured, (1...TunnelLifecyclePolicy.maximumReconnectAttempts).contains(configured) {
                normalized = configured
            } else {
                normalized = TunnelLifecyclePolicy.maximumReconnectAttempts
            }
            if configured != normalized {
                updated.profiles[index].curatedSSHOptions.maxReconnectAttempts = normalized
                didUpdate = true
            }
        }

        return (updated, didUpdate)
    }
}
