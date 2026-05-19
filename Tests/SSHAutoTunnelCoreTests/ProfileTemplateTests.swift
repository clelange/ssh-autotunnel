import XCTest
@testable import SSHAutoTunnelCore

final class ProfileTemplateTests: XCTestCase {
    func testExampleTemplateContainsAutomationFields() throws {
        let profile = ProfileTemplate.example()

        XCTAssertEqual(profile.name, "Example tunnel")
        XCTAssertEqual(profile.host, "ssh.example.org")
        XCTAssertEqual(profile.user, "alice")
        XCTAssertEqual(profile.sshPort, 22)
        XCTAssertEqual(profile.localSocksPort, 1083)
        XCTAssertEqual(profile.jumpHost, "bastion.example.org")
        XCTAssertEqual(profile.authMode, .passwordAndTOTP)
        XCTAssertEqual(profile.hostKeyPolicy, .acceptNew)
        XCTAssertEqual(profile.keychain.account, "alice")
        XCTAssertEqual(profile.keychain.passwordService, "example-password")
        XCTAssertEqual(profile.keychain.totpService, "example-totp-seed")
        XCTAssertEqual(profile.healthProbe, HealthProbe(host: "ssh.example.org", port: 22))
        XCTAssertEqual(profile.extraSSHOptions, ["-o", "IdentitiesOnly=yes"])

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }
}
