import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class BlockingProxyResponderTests: XCTestCase {
    func testHTTPRequestsReceiveStatusPage() {
        let request = HTTPRequest(
            method: "GET",
            path: "http://service.cern.ch/",
            headers: ["host": "service.cern.ch"],
            body: Data()
        )

        let response = BlockingProxyResponder.response(for: request, statusURL: "http://127.0.0.1:18483/status")
        let body = String(data: response.body, encoding: .utf8)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertTrue(body?.contains("Tunnel unavailable") == true)
        XCTAssertTrue(body?.contains("service.cern.ch") == true)
    }

    func testCONNECTRequestsFailCleanly() {
        let request = HTTPRequest(
            method: "CONNECT",
            path: "service.cern.ch:443",
            headers: ["host": "service.cern.ch:443"],
            body: Data()
        )

        let response = BlockingProxyResponder.response(for: request, statusURL: "http://127.0.0.1:18483/status")
        let body = String(data: response.body, encoding: .utf8)

        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(response.reason, "Bad Gateway")
        XCTAssertTrue(body?.contains("selected tunnel is unavailable") == true)
    }
}
