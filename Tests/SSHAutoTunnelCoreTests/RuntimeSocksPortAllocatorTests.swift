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
}
