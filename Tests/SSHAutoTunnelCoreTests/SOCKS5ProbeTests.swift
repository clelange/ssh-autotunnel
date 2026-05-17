import Darwin
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class SOCKS5ProbeTests: XCTestCase {
    func testProbeSucceedsAgainstNoAuthSOCKS5Server() throws {
        let server = try FakeSOCKS5Server(response: [0x05, 0x00])
        defer { server.stop() }

        XCTAssertTrue(SOCKS5Probe.probe(port: server.port))
    }

    func testProbeFailsAgainstNonSOCKSResponse() throws {
        let server = try FakeSOCKS5Server(response: [0x00, 0x00])
        defer { server.stop() }

        XCTAssertFalse(SOCKS5Probe.probe(port: server.port))
    }

    func testProbeFailsForClosedPort() throws {
        let port = try TestPortAllocator.freePort()
        XCTAssertFalse(SOCKS5Probe.probe(port: port, timeout: 1))
    }
}

private final class FakeSOCKS5Server {
    let port: Int
    private let fd: Int32
    private let response: [UInt8]
    private let queue = DispatchQueue(label: "fake.socks5.server")
    private var running = true

    init(response: [UInt8]) throws {
        self.response = response
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(socketFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        fd = socketFD
        port = Int(UInt16(bigEndian: addr.sin_port))
        start()
    }

    func stop() {
        running = false
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func start() {
        queue.async { [fd, response] in
            while self.running {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                let greetingLength = 3
                var buffer = [UInt8](repeating: 0, count: greetingLength)
                _ = buffer.withUnsafeMutableBytes {
                    Darwin.read(client, $0.baseAddress, greetingLength)
                }
                _ = response.withUnsafeBytes {
                    Darwin.write(client, $0.baseAddress, response.count)
                }
                close(client)
            }
        }
    }
}
