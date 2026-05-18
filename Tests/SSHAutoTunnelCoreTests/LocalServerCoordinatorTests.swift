import XCTest
@testable import SSHAutoTunnelCore

final class LocalServerCoordinatorTests: XCTestCase {
    func testStartsAllServerRolesAndTracksActivePorts() throws {
        let events = ServerEvents()
        let ports = LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484)
        let coordinator = LocalServerCoordinator<FakeServer> { role, port in
            FakeServer(role: role, port: port, events: events)
        }

        try coordinator.start(ports: ports)

        XCTAssertEqual(coordinator.activePorts, ports)
        XCTAssertEqual(events.values, [
            "start pac 18483",
            "start blockingProxy 18485",
            "start api 18484"
        ])
    }

    func testRestartIfNeededSkipsUnchangedPorts() throws {
        let events = ServerEvents()
        let ports = LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484)
        let coordinator = LocalServerCoordinator<FakeServer> { role, port in
            FakeServer(role: role, port: port, events: events)
        }
        try coordinator.start(ports: ports)
        events.values.removeAll()

        let didRestart = try coordinator.restartIfNeeded(ports: ports)

        XCTAssertFalse(didRestart)
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertEqual(coordinator.activePorts, ports)
    }

    func testRestartFailureStopsPartialServersAndRestoresPreviousPorts() throws {
        let events = ServerEvents()
        let oldPorts = LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484)
        let newPorts = LocalServerPorts(pacHTTPPort: 19083, blockingHTTPProxyPort: 19085, apiHTTPPort: 19084)
        var failingPort: Int?
        let coordinator = LocalServerCoordinator<FakeServer> { role, port in
            FakeServer(role: role, port: port, events: events, failingPort: failingPort)
        }
        try coordinator.start(ports: oldPorts)
        events.values.removeAll()
        failingPort = newPorts.apiHTTPPort

        XCTAssertThrowsError(try coordinator.restartIfNeeded(ports: newPorts))

        XCTAssertEqual(coordinator.activePorts, oldPorts)
        XCTAssertEqual(events.values, [
            "stop pac 18483",
            "stop blockingProxy 18485",
            "stop api 18484",
            "start pac 19083",
            "start blockingProxy 19085",
            "start api 19084",
            "stop pac 19083",
            "stop blockingProxy 19085",
            "start pac 18483",
            "start blockingProxy 18485",
            "start api 18484"
        ])
    }

    func testStopClearsActivePorts() throws {
        let events = ServerEvents()
        let ports = LocalServerPorts(pacHTTPPort: 18483, blockingHTTPProxyPort: 18485, apiHTTPPort: 18484)
        let coordinator = LocalServerCoordinator<FakeServer> { role, port in
            FakeServer(role: role, port: port, events: events)
        }
        try coordinator.start(ports: ports)
        events.values.removeAll()

        coordinator.stop()

        XCTAssertNil(coordinator.activePorts)
        XCTAssertEqual(events.values, [
            "stop pac 18483",
            "stop blockingProxy 18485",
            "stop api 18484"
        ])
    }
}

private final class ServerEvents {
    var values: [String] = []
}

private final class FakeServer: LocalServerControlling {
    enum Failure: Error {
        case start
    }

    let role: LocalServerRole
    let port: Int
    let events: ServerEvents
    let failingPort: Int?

    init(role: LocalServerRole, port: Int, events: ServerEvents, failingPort: Int? = nil) {
        self.role = role
        self.port = port
        self.events = events
        self.failingPort = failingPort
    }

    func start() throws {
        events.values.append("start \(role) \(port)")
        if port == failingPort {
            throw Failure.start
        }
    }

    func stop() {
        events.values.append("stop \(role) \(port)")
    }
}
