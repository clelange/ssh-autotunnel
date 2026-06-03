import Darwin
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class LocalHTTPServerTests: XCTestCase {
    func testServesPACResponse() async throws {
        let profile = TunnelProfile(name: "Test", host: "ssh.example.org", localSocksPort: 1099)
        let config = AppConfiguration(
            profiles: [profile],
            pacRules: [PACRule(name: "Example", domainPattern: "*.example.org", profileID: profile.id)]
        )
        let startedServer = try TestPortAllocator.startedLocalHTTPServer(label: "test.pac.server") { request in
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
        let server = startedServer.server
        let port = startedServer.port
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/proxy.pac")!)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body = String(data: data, encoding: .utf8)
        XCTAssertTrue(body?.contains("SOCKS5 127.0.0.1:1099") == true)
    }

    func testReceivesCompletePOSTBody() async throws {
        let startedServer = try TestPortAllocator.startedLocalHTTPServer(label: "test.post.server") { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api")
            return HTTPResponse.text(String(data: request.body, encoding: .utf8) ?? "")
        }
        let server = startedServer.server
        let port = startedServer.port
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

    func testRoutePathStripsQuery() throws {
        let startedServer = try TestPortAllocator.startedLocalHTTPServer(label: "test.route.server") { request in
            HTTPResponse.text(request.routePath)
        }
        let server = startedServer.server
        let port = startedServer.port
        defer { server.stop() }

        let response = try rawHTTPResponse(
            port: port,
            request: "GET /proxy.pac?v=123 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(response.hasSuffix("/proxy.pac"))
    }

    func testRejectsOversizedHeaders() throws {
        let startedServer = try TestPortAllocator.startedLocalHTTPServer(
            label: "test.header-limit.server",
            limits: LocalHTTPServerLimits(maxHeaderBytes: 64, maxBodyBytes: 1024)
        ) { _ in
            XCTFail("Handler should not receive oversized headers")
            return .text("unexpected")
        }
        let server = startedServer.server
        let port = startedServer.port
        defer { server.stop() }

        let largeHeader = String(repeating: "A", count: 100)
        let response = try rawHTTPResponse(
            port: port,
            request: "GET / HTTP/1.1\r\nX-Large: \(largeHeader)\r\n\r\n"
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 431 Request Header Fields Too Large"))
    }

    func testRejectsOversizedBody() throws {
        let startedServer = try TestPortAllocator.startedLocalHTTPServer(
            label: "test.body-limit.server",
            limits: LocalHTTPServerLimits(maxHeaderBytes: 1024, maxBodyBytes: 8)
        ) { _ in
            XCTFail("Handler should not receive oversized bodies")
            return .text("unexpected")
        }
        let server = startedServer.server
        let port = startedServer.port
        defer { server.stop() }

        let response = try rawHTTPResponse(
            port: port,
            request: "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 9\r\n\r\n123456789"
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413 Payload Too Large"))
    }

    func testRejectsInvalidContentLength() throws {
        let startedServer = try TestPortAllocator.startedLocalHTTPServer(label: "test.invalid-content-length.server") { _ in
            XCTFail("Handler should not receive invalid Content-Length requests")
            return .text("unexpected")
        }
        let server = startedServer.server
        let port = startedServer.port
        defer { server.stop() }

        let response = try rawHTTPResponse(
            port: port,
            request: "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: nope\r\n\r\n"
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    func testAcceptsMissingContentLengthForEmptyBody() throws {
        let startedServer = try TestPortAllocator.startedLocalHTTPServer(label: "test.missing-content-length.server") { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertTrue(request.body.isEmpty)
            return .text("empty")
        }
        let server = startedServer.server
        let port = startedServer.port
        defer { server.stop() }

        let response = try rawHTTPResponse(
            port: port,
            request: "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(response.hasSuffix("empty"))
    }

    func testRejectsInvalidPort() {
        XCTAssertThrowsError(try LocalHTTPServer(port: 0, label: "test.invalid") { _ in .text("no") }) { error in
            XCTAssertEqual(error as? LocalHTTPServerError, .invalidPort(0))
        }
        XCTAssertThrowsError(try LocalHTTPServer(port: 70_000, label: "test.invalid") { _ in .text("no") }) { error in
            XCTAssertEqual(error as? LocalHTTPServerError, .invalidPort(70_000))
        }
    }

    private func rawHTTPResponse(port: Int, request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let requestData = Array(request.utf8)
        try requestData.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: sent), buffer.count - sent)
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                sent += result
            }
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bufferSize = buffer.count
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, bufferSize)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard count > 0 else { break }
            response.append(contentsOf: buffer.prefix(count))
        }
        return String(data: response, encoding: .utf8) ?? ""
    }
}
