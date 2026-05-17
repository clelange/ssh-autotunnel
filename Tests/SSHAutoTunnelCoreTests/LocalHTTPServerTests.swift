import Foundation
import Darwin
import XCTest
@testable import SSHAutoTunnelCore

final class LocalHTTPServerTests: XCTestCase {
    func testServesPACResponse() async throws {
        let port = try Self.freePort()
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1099)
        let config = AppConfiguration(
            profiles: [profile],
            pacRules: [PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)]
        )
        let server = LocalHTTPServer(port: port, label: "test.pac.server") { request in
            XCTAssertTrue(request.path.hasPrefix("/proxy.pac"))
            let pac = PACGenerator.generate(context: PACGenerationContext(
                configuration: config,
                statuses: [profile.id: TunnelRuntimeStatus(profileID: profile.id, health: .healthy)]
            ))
            return HTTPResponse(
                headers: [
                    "Content-Type": "application/x-ns-proxy-autoconfig; charset=utf-8",
                    "Cache-Control": "no-store"
                ],
                body: Data(pac.utf8)
            )
        }
        try server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/proxy.pac")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body = String(data: data, encoding: .utf8)
        XCTAssertTrue(body?.contains("SOCKS5 127.0.0.1:1099") == true)
    }

    func testReceivesCompletePOSTBody() async throws {
        let port = try Self.freePort()
        let server = LocalHTTPServer(port: port, label: "test.post.server") { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api")
            return HTTPResponse.text(String(data: request.body, encoding: .utf8) ?? "")
        }
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"action":"status","profileName":"CERN lxplus"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"action":"status","profileName":"CERN lxplus"}"#)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
