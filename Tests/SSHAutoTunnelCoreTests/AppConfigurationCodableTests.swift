import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class AppConfigurationCodableTests: XCTestCase {
    func testDecodesLegacyConfigurationWithoutBlockingProxyPort() throws {
        let json = Data("""
        {
          "profiles": [],
          "pacRules": [],
          "networkRules": [],
          "pacHTTPPort": 18483,
          "apiHTTPPort": 18484,
          "apiToken": "token",
          "proxyApplyMode": "manual"
        }
        """.utf8)

        let config = try JSONDecoder().decode(AppConfiguration.self, from: json)

        XCTAssertEqual(config.blockingHTTPProxyPort, 18485)
        XCTAssertEqual(config.apiToken, "token")
    }

    func testEncodesBlockingProxyPort() throws {
        let config = AppConfiguration(blockingHTTPProxyPort: 19000)
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["blockingHTTPProxyPort"] as? Int, 19000)
    }
}
