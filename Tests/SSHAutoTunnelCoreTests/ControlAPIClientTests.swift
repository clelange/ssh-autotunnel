import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class ControlAPIClientTests: XCTestCase {
    func testSendsAuthenticatedControlRequest() async throws {
        let port = try TestPortAllocator.freePort()
        let expectedToken = "test-token"
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let server = try LocalHTTPServer(port: port, label: "test.api.client") { request in
            XCTAssertEqual(request.headers["authorization"], "Bearer \(expectedToken)")
            XCTAssertEqual(request.path, "/api")
            let control = try? decoder.decode(ControlRequest.self, from: request.body)
            XCTAssertEqual(control?.action, .connect)
            XCTAssertEqual(control?.profileName, "CERN lxplus")

            let response = ControlResponse(ok: true, message: "Connecting CERN lxplus")
            return HTTPResponse.json(response, encoder: encoder)
        }
        try server.start()
        defer { server.stop() }

        let client = ControlAPIClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: expectedToken)
        let response = try await client.send(ControlRequest(action: .connect, profileName: "CERN lxplus"))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "Connecting CERN lxplus")
    }

    func testThrowsForUnauthorizedResponse() async throws {
        let port = try TestPortAllocator.freePort()
        let server = try LocalHTTPServer(port: port, label: "test.api.unauthorized") { _ in
            HTTPResponse.error(401, "Unauthorized", "Missing or invalid API token")
        }
        try server.start()
        defer { server.stop() }

        let client = ControlAPIClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "wrong-token")

        do {
            _ = try await client.send(ControlRequest(action: .status))
            XCTFail("Expected unauthorized response to throw")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ControlAPIClient")
            XCTAssertEqual(nsError.code, 401)
            XCTAssertEqual(nsError.localizedDescription, "Missing or invalid API token")
        }
    }

    func testDecodesKeychainServiceStatuses() async throws {
        let port = try TestPortAllocator.freePort()
        let expectedToken = "test-token"
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let server = try LocalHTTPServer(port: port, label: "test.api.keychain-status") { request in
            XCTAssertEqual(request.headers["authorization"], "Bearer \(expectedToken)")
            let control = try? decoder.decode(ControlRequest.self, from: request.body)
            XCTAssertEqual(control?.action, .checkSSHAuto2FA)

            return HTTPResponse.json(
                ControlResponse(
                    ok: true,
                    message: "Checked",
                    sshAuto2FAServiceStatuses: [
                        SSHAuto2FAServiceStatus(
                            requirement: SSHAuto2FAServiceRequirement(
                                profileName: "CERN lxplus",
                                kind: .totpSeed,
                                service: "cern-lxplus-otp-secret",
                                account: "lange_c"
                            ),
                            state: .available
                        ),
                        SSHAuto2FAServiceStatus(
                            requirement: SSHAuto2FAServiceRequirement(
                                profileName: "PSI Tier-3",
                                kind: .password,
                                service: "psit3-password",
                                account: "lange_c"
                            ),
                            state: .unreadable("Access denied")
                        )
                    ]
                ),
                encoder: encoder
            )
        }
        try server.start()
        defer { server.stop() }

        let client = ControlAPIClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: expectedToken)
        let response = try await client.send(ControlRequest(action: .checkSSHAuto2FA))

        XCTAssertEqual(response.sshAuto2FAServiceStatuses?.map(\.state), [
            .available,
            .unreadable("Access denied")
        ])
    }
}
