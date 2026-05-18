import Darwin
import XCTest
@testable import SSHAutoTunnelCore

final class TunnelManagerProcessTests: XCTestCase {
    func testManualStopSuppressesLaterProcessTermination() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let started = expectation(description: "started")
        let stopped = expectation(description: "stopped")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
            if status.profileID == profile.id, status.health == .stopped {
                stopped.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)

        manager.stop(profileID: profile.id)
        wait(for: [stopped], timeout: 1)
        session.exit(status: SIGTERM)
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(manager.status(for: profile.id).health, .stopped)
        XCTAssertEqual(launcher.sessions.count, 1)
    }

    func testUnexpectedExitReconnectsWhenEnabled() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "first start")
        let secondStart = expectation(description: "second start")
        var startCount = 0
        manager.onStatusChange = { status in
            guard status.profileID == profile.id, status.message == "SSH process started" else { return }
            startCount += 1
            if startCount == 1 {
                firstStart.fulfill()
            } else if startCount == 2 {
                secondStart.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)
        try XCTUnwrap(launcher.sessions.first).exit(status: 255)
        wait(for: [secondStart], timeout: 1)

        XCTAssertEqual(launcher.sessions.count, 2)
        XCTAssertEqual(manager.status(for: profile.id).health, .connecting)
    }

    func testRepeatedHealthFailureRestartsTunnel() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in false },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "first start")
        let secondStart = expectation(description: "second start")
        var startCount = 0
        manager.onStatusChange = { status in
            guard status.profileID == profile.id, status.message == "SSH process started" else { return }
            startCount += 1
            if startCount == 1 {
                firstStart.fulfill()
            } else if startCount == 2 {
                secondStart.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)

        manager.runHealthCheckForTesting()
        XCTAssertEqual(manager.status(for: profile.id).health, .unhealthy)

        manager.runHealthCheckForTesting()
        wait(for: [secondStart], timeout: 1)

        XCTAssertEqual(launcher.sessions.count, 2)
        XCTAssertEqual(launcher.sessions.first?.terminateCallCount, 1)
    }

    private func testProfile(autoReconnect: Bool) -> TunnelProfile {
        TunnelProfile(
            name: "Test",
            host: "ssh.example.org",
            localSocksPort: 1099,
            authMode: .none,
            autoReconnect: autoReconnect
        )
    }
}

private final class FakeSSHProcessLauncher: SSHProcessLaunching {
    private var nextPID: Int32 = 10_000
    private let lock = NSLock()
    private(set) var sessions: [FakeSSHProcessSession] = []

    func launch(
        command: SSHCommand,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession {
        lock.lock()
        defer { lock.unlock() }
        let session = FakeSSHProcessSession(pid: nextPID, onTermination: onTermination)
        nextPID += 1
        sessions.append(session)
        return session
    }
}

private final class FakeSSHProcessSession: SSHProcessSession {
    let processIdentifier: Int32
    private let onTermination: (SSHProcessSession) -> Void
    private(set) var terminationStatus: Int32 = 0
    private(set) var isRunning = true
    private(set) var terminateCallCount = 0
    private(set) var forceKillCallCount = 0
    private(set) var writes: [Data] = []

    init(pid: Int32, onTermination: @escaping (SSHProcessSession) -> Void) {
        processIdentifier = pid
        self.onTermination = onTermination
    }

    func write(_ data: Data) {
        writes.append(data)
    }

    func terminate() {
        terminateCallCount += 1
        isRunning = false
        terminationStatus = SIGTERM
    }

    func forceKill() {
        forceKillCallCount += 1
    }

    func exit(status: Int32) {
        terminationStatus = status
        isRunning = false
        onTermination(self)
    }
}
