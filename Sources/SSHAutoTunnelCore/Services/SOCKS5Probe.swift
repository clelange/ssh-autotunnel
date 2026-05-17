import Darwin
import Foundation

public enum SOCKS5Probe {
    public static func probe(host: String = "127.0.0.1", port: Int, timeout: TimeInterval = 2) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let timeoutValue = timeval(tv_sec: Int(timeout), tv_usec: 0)
        var sendTimeout = timeoutValue
        var receiveTimeout = timeoutValue
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return false }

        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        guard greeting.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, greeting.count) }) == greeting.count else {
            return false
        }

        let expectedResponseLength = 2
        var response = [UInt8](repeating: 0, count: expectedResponseLength)
        let bytesRead = response.withUnsafeMutableBytes {
            Darwin.read(fd, $0.baseAddress, expectedResponseLength)
        }
        return bytesRead == 2 && response == [0x05, 0x00]
    }
}
