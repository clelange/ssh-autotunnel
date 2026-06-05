import Darwin
import Foundation

struct RuntimeSocksPortAllocation: Equatable, Sendable {
    var port: Int
    var usedPreferredPort: Bool
}

struct RuntimeSocksPortAllocationError: LocalizedError, Equatable, Sendable {
    var preferredPort: Int

    var errorDescription: String? {
        "Could not find an available local SOCKS port at or above \(preferredPort)"
    }
}

enum RuntimeSocksPortAllocator {
    static func allocate(
        preferredPort: Int,
        reservedPorts: Set<Int>,
        isPortAvailable: (Int) -> Bool = LoopbackPortProbe.canBind
    ) throws -> RuntimeSocksPortAllocation {
        guard PortConfigurationValidator.validRange.contains(preferredPort) else {
            throw RuntimeSocksPortAllocationError(preferredPort: preferredPort)
        }

        for port in preferredPort...PortConfigurationValidator.validRange.upperBound {
            guard !reservedPorts.contains(port), isPortAvailable(port) else { continue }
            return RuntimeSocksPortAllocation(port: port, usedPreferredPort: port == preferredPort)
        }

        throw RuntimeSocksPortAllocationError(preferredPort: preferredPort)
    }
}

enum LoopbackPortProbe {
    static func canBind(port: Int) -> Bool {
        guard PortConfigurationValidator.validRange.contains(port) else { return false }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        ) == 0 else {
            return false
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
