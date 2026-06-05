import Darwin
import XCTest
@testable import SSHAutoTunnelCore

final class RuntimeSocksPortAllocatorTests: XCTestCase {
    func testUsesPreferredPortWhenAvailable() throws {
        let allocation = try RuntimeSocksPortAllocator.allocate(
            preferredPort: 1083,
            reservedPorts: [1084],
            isPortAvailable: { $0 == 1083 }
        )

        XCTAssertEqual(allocation, RuntimeSocksPortAllocation(port: 1083, usedPreferredPort: true))
    }

    func testSkipsReservedAndUnavailablePorts() throws {
        var probedPorts: [Int] = []
        let allocation = try RuntimeSocksPortAllocator.allocate(
            preferredPort: 1083,
            reservedPorts: [1084],
            isPortAvailable: { port in
                probedPorts.append(port)
                return port == 1085
            }
        )

        XCTAssertEqual(allocation, RuntimeSocksPortAllocation(port: 1085, usedPreferredPort: false))
        XCTAssertEqual(probedPorts, [1083, 1085])
    }

    func testThrowsWhenNoCandidateIsAvailable() {
        XCTAssertThrowsError(
            try RuntimeSocksPortAllocator.allocate(
                preferredPort: 65_535,
                reservedPorts: [65_535],
                isPortAvailable: { _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeSocksPortAllocationError, RuntimeSocksPortAllocationError(preferredPort: 65_535))
        }
    }

    func testLoopbackProbeReportsBoundPortUnavailable() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(descriptor, 1), 0)

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(descriptor, sockaddrPointer, &boundAddressLength)
            }
        }
        XCTAssertEqual(nameResult, 0)

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        XCTAssertFalse(LoopbackPortProbe.canBind(port: port))
    }
}
