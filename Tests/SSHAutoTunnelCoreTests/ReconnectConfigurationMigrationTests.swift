import XCTest
@testable import SSHAutoTunnelCore

final class ReconnectConfigurationMigrationTests: XCTestCase {
    func testMigrationCapsUnlimitedAndOversizedLimitsAndDisablesZero() {
        var unlimited = TunnelProfile(name: "Unlimited", host: "one.example.org", localSocksPort: 1081)
        unlimited.curatedSSHOptions.maxReconnectAttempts = nil
        var oversized = TunnelProfile(name: "Oversized", host: "two.example.org", localSocksPort: 1082)
        oversized.curatedSSHOptions.maxReconnectAttempts = 99
        var disabled = TunnelProfile(name: "Disabled", host: "three.example.org", localSocksPort: 1083)
        disabled.curatedSSHOptions.maxReconnectAttempts = 0
        var preserved = TunnelProfile(name: "Preserved", host: "four.example.org", localSocksPort: 1084)
        preserved.curatedSSHOptions.maxReconnectAttempts = 2
        var shortcutSentinel = TunnelProfile(name: "Shortcut Sentinel", host: "five.example.org", localSocksPort: 1085)
        shortcutSentinel.curatedSSHOptions.maxReconnectAttempts = -1

        let result = ReconnectConfigurationMigration.migrate(
            AppConfiguration(profiles: [unlimited, oversized, disabled, preserved, shortcutSentinel])
        )

        XCTAssertTrue(result.didUpdate)
        XCTAssertEqual(result.configuration.profiles.map { $0.curatedSSHOptions.maxReconnectAttempts }, [3, 3, 3, 2, 3])
        XCTAssertEqual(result.configuration.profiles.map(\.autoReconnect), [true, true, false, true, true])
    }
}
