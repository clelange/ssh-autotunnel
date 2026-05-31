import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class ControlAPIRouterTests: XCTestCase {
    func testRejectsUnauthorizedRequests() {
        let router = makeRouter(token: "expected-token")

        let response = router.response(for: request(headers: ["authorization": "Bearer wrong-token"]))

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "Missing or invalid API token")
    }

    func testReturnsStatusForAuthorizedGETStatusRequest() throws {
        let router = makeRouter(statusMessage: "status-ok")

        let response = router.response(for: request(method: "GET", path: "/status"))
        let controlResponse = try decode(response)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(controlResponse.ok)
        XCTAssertEqual(controlResponse.message, "status-ok")
    }

    func testDispatchesAuthorizedPOSTAPIRequest() throws {
        var handledRequest: ControlRequest?
        let router = makeRouter { request in
            handledRequest = request
            return ControlResponse(ok: true, message: "handled \(request.action.rawValue)")
        }
        let body = try JSONEncoder().encode(ControlRequest(action: .connect, profileName: "CERN lxplus"))

        let response = router.response(for: request(body: body))
        let controlResponse = try decode(response)

        XCTAssertEqual(handledRequest?.action, .connect)
        XCTAssertEqual(handledRequest?.profileName, "CERN lxplus")
        XCTAssertTrue(controlResponse.ok)
        XCTAssertEqual(controlResponse.message, "handled connect")
    }

    func testDispatchesHopControlAction() throws {
        var handledRequest: ControlRequest?
        let router = makeRouter { request in
            handledRequest = request
            return ControlResponse(ok: true, message: "handled \(request.action.rawValue)")
        }
        let body = try JSONEncoder().encode(ControlRequest(action: .connectHop, profileName: "PSI General"))

        let response = router.response(for: request(body: body))
        let controlResponse = try decode(response)

        XCTAssertEqual(handledRequest?.action, .connectHop)
        XCTAssertEqual(handledRequest?.profileName, "PSI General")
        XCTAssertTrue(controlResponse.ok)
        XCTAssertEqual(controlResponse.message, "handled connectHop")
    }

    func testReturnsNotFoundForUnknownAuthorizedRoute() {
        let router = makeRouter()

        let response = router.response(for: request(method: "GET", path: "/unknown"))

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "Unknown API route")
    }

    func testInvalidPOSTBodyReturnsStatusShapedFailure() throws {
        let router = makeRouter(statusMessage: "status snapshot")

        let response = router.response(for: request(body: Data("{ invalid json".utf8)))
        let controlResponse = try decode(response)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(controlResponse.ok)
        XCTAssertTrue(controlResponse.message.contains("data"))
        XCTAssertEqual(controlResponse.status?.pacURL, "http://127.0.0.1:18483/proxy.pac")
    }

    private func makeRouter(
        token: String = "test-token",
        statusMessage: String = "OK",
        controlHandler: @escaping (ControlRequest) -> ControlResponse = { _ in ControlResponse(ok: true, message: "handled") }
    ) -> ControlAPIRouter {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return ControlAPIRouter(
            tokenProvider: { token },
            statusProvider: {
                ControlResponse(
                    ok: true,
                    message: statusMessage,
                    status: AppStatusSnapshot(
                        pacURL: "http://127.0.0.1:18483/proxy.pac",
                        proxyDisabledByNetworkPolicy: false,
                        matchedNetworkRule: nil,
                        profiles: []
                    )
                )
            },
            controlHandler: controlHandler,
            encoder: encoder
        )
    }

    private func request(
        method: String = "POST",
        path: String = "/api",
        headers: [String: String] = ["authorization": "Bearer test-token"],
        body: Data = Data()
    ) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func decode(_ response: HTTPResponse) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: response.body)
    }
}
