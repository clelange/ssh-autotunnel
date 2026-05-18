import Foundation

public enum LocalServerRole: CaseIterable, Equatable, Sendable {
    case pac
    case blockingProxy
    case api
}

public protocol LocalServerControlling: AnyObject {
    func start() throws
    func stop()
}

extension LocalHTTPServer: LocalServerControlling {}

public struct LocalServerPorts: Equatable, Sendable {
    public var pacHTTPPort: Int
    public var blockingHTTPProxyPort: Int
    public var apiHTTPPort: Int

    public init(pacHTTPPort: Int, blockingHTTPProxyPort: Int, apiHTTPPort: Int) {
        self.pacHTTPPort = pacHTTPPort
        self.blockingHTTPProxyPort = blockingHTTPProxyPort
        self.apiHTTPPort = apiHTTPPort
    }

    public init(configuration: AppConfiguration) {
        self.init(
            pacHTTPPort: configuration.pacHTTPPort,
            blockingHTTPProxyPort: configuration.blockingHTTPProxyPort,
            apiHTTPPort: configuration.apiHTTPPort
        )
    }

    public func port(for role: LocalServerRole) -> Int {
        switch role {
        case .pac:
            pacHTTPPort
        case .blockingProxy:
            blockingHTTPProxyPort
        case .api:
            apiHTTPPort
        }
    }
}

public final class LocalServerCoordinator<Server: LocalServerControlling> {
    public typealias Factory = (LocalServerRole, Int) throws -> Server

    private let makeServer: Factory
    private var servers: [LocalServerRole: Server] = [:]
    public private(set) var activePorts: LocalServerPorts?

    public init(makeServer: @escaping Factory) {
        self.makeServer = makeServer
    }

    deinit {
        stop()
    }

    public func start(ports: LocalServerPorts) throws {
        let nextServers = try startBundle(ports: ports)
        stop()
        servers = nextServers
        activePorts = ports
    }

    @discardableResult
    public func restartIfNeeded(ports: LocalServerPorts) throws -> Bool {
        guard activePorts != ports else { return false }
        let previousPorts = activePorts

        stop()
        do {
            try start(ports: ports)
            return true
        } catch {
            stop()
            if let previousPorts {
                try? start(ports: previousPorts)
            }
            throw error
        }
    }

    public func stop() {
        for role in LocalServerRole.allCases {
            servers[role]?.stop()
        }
        servers.removeAll()
        activePorts = nil
    }

    private func startBundle(ports: LocalServerPorts) throws -> [LocalServerRole: Server] {
        var started: [LocalServerRole: Server] = [:]
        do {
            for role in LocalServerRole.allCases {
                let server = try makeServer(role, ports.port(for: role))
                try server.start()
                started[role] = server
            }
            return started
        } catch {
            for role in LocalServerRole.allCases {
                started[role]?.stop()
            }
            throw error
        }
    }
}
