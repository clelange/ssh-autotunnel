import Darwin
import Foundation
@testable import SSHAutoTunnelCore

enum TestPortAllocator {
    static func freePort() throws -> Int {
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

    static func startedLocalHTTPServer(
        label: String,
        retries: Int = 20,
        handler: @escaping LocalHTTPServer.Handler
    ) throws -> (server: LocalHTTPServer, port: Int) {
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            let port = try freePort()
            let server = try LocalHTTPServer(port: port, label: "\(label).\(attempt)", handler: handler)
            do {
                try server.start()
                return (server, port)
            } catch {
                server.stop()
                lastError = error
                guard isRetryablePortRace(error) else {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        throw lastError ?? NSError(
            domain: "TestPortAllocator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not start local test server after \(retries) attempts"]
        )
    }

    private static func isRetryablePortRace(_ error: Error) -> Bool {
        guard case .startupFailed(let message) = error as? LocalHTTPServerError else {
            return false
        }
        return message.localizedCaseInsensitiveContains("address already in use")
            || message.localizedCaseInsensitiveContains("eaddrinuse")
            || message.contains("error 48")
    }
}
