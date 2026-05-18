import XCTest
@testable import SSHAutoTunnelCore

final class PortConfigurationValidatorTests: XCTestCase {
    func testDefaultConfigurationIsValid() {
        XCTAssertNoThrow(try PortConfigurationValidator.validate(.defaultConfiguration()))
    }

    func testRejectsPortsOutsideValidRange() {
        let profile = TunnelProfile(
            name: "Invalid",
            host: "example.org",
            sshPort: 70_000,
            localSocksPort: 0,
            healthProbe: HealthProbe(host: "example.org", port: -1)
        )
        let config = AppConfiguration(
            profiles: [profile],
            pacHTTPPort: -1,
            blockingHTTPProxyPort: 65_536,
            apiHTTPPort: 0
        )

        let messages = PortConfigurationValidator.validationMessages(for: config)

        XCTAssertTrue(messages.contains("PAC HTTP port must be between 1 and 65535"))
        XCTAssertTrue(messages.contains("Blocking proxy port must be between 1 and 65535"))
        XCTAssertTrue(messages.contains("API HTTP port must be between 1 and 65535"))
        XCTAssertTrue(messages.contains("Invalid SSH port must be between 1 and 65535"))
        XCTAssertTrue(messages.contains("Invalid local SOCKS port must be between 1 and 65535"))
        XCTAssertTrue(messages.contains("Invalid health probe port must be between 1 and 65535"))
    }

    func testRejectsDuplicateServerAndLocalSocksPorts() {
        let profile = TunnelProfile(name: "Duplicate", host: "example.org", localSocksPort: 18483)
        let otherProfile = TunnelProfile(name: "Other", host: "other.example.org", localSocksPort: 18483)
        let config = AppConfiguration(
            profiles: [profile, otherProfile],
            pacHTTPPort: 18483,
            blockingHTTPProxyPort: 18484,
            apiHTTPPort: 18484
        )

        let messages = PortConfigurationValidator.validationMessages(for: config)

        XCTAssertTrue(messages.contains("Port 18483 is used by PAC HTTP port, Duplicate local SOCKS port, Other local SOCKS port"))
        XCTAssertTrue(messages.contains("Port 18484 is used by API HTTP port, Blocking proxy port"))
    }

    func testThrowsStructuredError() {
        var config = AppConfiguration.defaultConfiguration()
        config.apiHTTPPort = config.pacHTTPPort

        XCTAssertThrowsError(try PortConfigurationValidator.validate(config)) { error in
            let portError = error as? PortConfigurationError
            XCTAssertEqual(portError?.messages, ["Port 18483 is used by PAC HTTP port, API HTTP port"])
        }
    }
}
