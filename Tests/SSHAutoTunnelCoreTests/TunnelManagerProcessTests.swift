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

    func testUnexpectedExitIncludesLastSSHOutputInStatus() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: false)
        let manager = TunnelManager(
            processLauncher: launcher,
            startsHealthTimer: false
        )
        let started = expectation(description: "started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)

        session.emit("debug line\r\nPermission denied, please try again.\r\n")
        session.exit(status: 255)
        waitUntil("exit status includes SSH output") {
            manager.status(for: profile.id).health == .failed
        }

        XCTAssertEqual(
            manager.status(for: profile.id).message,
            "SSH exited with status 255: Permission denied, please try again."
        )
    }

    func testRepeatedHealthFailureRestartsTunnel() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in false },
            reconnectDelay: { _ in 0.01 },
            initialReadinessGracePeriod: 0,
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

    func testInitialHealthFailureWaitsForReadinessGrace() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in false },
            initialReadinessGracePeriod: 60,
            startsHealthTimer: false
        )
        let started = expectation(description: "started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        manager.runHealthCheckForTesting()

        let status = manager.status(for: profile.id)
        XCTAssertEqual(status.health, .connecting)
        XCTAssertEqual(status.message, "Waiting for SSH authentication and SOCKS5 listener")
        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(launcher.sessions.first?.terminateCallCount, 0)
    }

    func testTOTPIsGeneratedWhenPromptArrivesNotAtLaunch() throws {
        let launcher = FakeSSHProcessLauncher()
        let keychain = FakeGenericPasswordReader(values: ["otp-service": "JBSWY3DPEHPK3PXP"])
        var generatedSeeds: [String] = []
        let profile = TunnelProfile(
            name: "Test",
            host: "ssh.example.org",
            localSocksPort: 1099,
            authMode: .totp,
            keychain: KeychainReference(account: "alice", totpService: "otp-service")
        )
        let manager = TunnelManager(
            keychain: keychain,
            processLauncher: launcher,
            totpGenerator: { seed in
                generatedSeeds.append(seed)
                return "654321"
            },
            startsHealthTimer: false
        )
        let started = expectation(description: "started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)

        XCTAssertTrue(keychain.reads.isEmpty)
        XCTAssertTrue(generatedSeeds.isEmpty)

        session.emit("Verification code:")
        waitUntil("TOTP reply is written") {
            session.writtenStrings == ["654321\n"]
        }

        XCTAssertEqual(keychain.reads, [FakeGenericPasswordReader.Read(service: "otp-service", account: "alice")])
        XCTAssertEqual(generatedSeeds, ["JBSWY3DPEHPK3PXP"])

        session.emit("Verification code:")
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(session.writtenStrings, ["654321\n"])
        XCTAssertEqual(keychain.reads.count, 1)
    }

    func testStrictHostKeyPolicyRejectsInteractiveHostKeyPrompt() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = TunnelProfile(
            name: "Strict",
            host: "ssh.example.org",
            localSocksPort: 1099,
            hostKeyPolicy: .strict
        )
        let manager = TunnelManager(
            processLauncher: launcher,
            startsHealthTimer: false
        )
        let started = expectation(description: "started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)

        session.emit("Are you sure you want to continue connecting (yes/no/[fingerprint])?")
        waitUntil("strict host key rejection") {
            manager.status(for: profile.id).health == .failed
        }

        XCTAssertTrue(manager.status(for: profile.id).message.contains("host key prompt blocked"))
        XCTAssertTrue(session.writes.isEmpty)
        XCTAssertEqual(session.terminateCallCount, 1)
    }

    func testLogsRedactedPromptAnnotationsAndOutput() throws {
        let launcher = FakeSSHProcessLauncher()
        let keychain = FakeGenericPasswordReader(values: [
            "password-service": "secret-password",
            "otp-service": "JBSWY3DPEHPK3PXP"
        ])
        let profile = TunnelProfile(
            name: "Redacted",
            host: "ssh.example.org",
            localSocksPort: 1099,
            authMode: .passwordAndTOTP,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "password-service",
                totpService: "otp-service"
            )
        )
        let manager = TunnelManager(
            keychain: keychain,
            processLauncher: launcher,
            totpGenerator: { _ in "654321" },
            startsHealthTimer: false
        )
        var log = ""
        let started = expectation(description: "started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
        }
        manager.onLog = { profileID, text in
            if profileID == profile.id {
                log += text
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)

        session.emit("Password:")
        waitUntil("password reply is written") {
            session.writtenStrings == ["secret-password\n"]
        }
        session.emit("secret-password\r\nVerification code:")
        waitUntil("TOTP reply is written") {
            session.writtenStrings == ["secret-password\n", "654321\n"]
        }
        session.emit("654321\r\n")
        waitUntil("prompt annotations are logged") {
            log.contains("TOTP sent (<redacted>)")
        }

        XCTAssertTrue(log.contains("[tunnel] password prompt detected"))
        XCTAssertTrue(log.contains("[tunnel] password sent (<redacted>)"))
        XCTAssertTrue(log.contains("[tunnel] TOTP prompt detected"))
        XCTAssertTrue(log.contains("[tunnel] TOTP sent (<redacted>)"))
        XCTAssertFalse(log.contains("secret-password"))
        XCTAssertFalse(log.contains("654321"))
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

    private func waitUntil(_ description: String, timeout: TimeInterval = 1, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private final class FakeSSHProcessLauncher: SSHProcessLaunching {
    private var nextPID: Int32 = 10_000
    private let lock = NSLock()
    private(set) var commands: [SSHCommand] = []
    private(set) var sessions: [FakeSSHProcessSession] = []

    func launch(
        command: SSHCommand,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession {
        lock.lock()
        defer { lock.unlock() }
        commands.append(command)
        let session = FakeSSHProcessSession(pid: nextPID, onOutput: onOutput, onTermination: onTermination)
        nextPID += 1
        sessions.append(session)
        return session
    }
}

private final class FakeSSHProcessSession: SSHProcessSession {
    let processIdentifier: Int32
    private let onOutput: (Data) -> Void
    private let onTermination: (SSHProcessSession) -> Void
    private(set) var terminationStatus: Int32 = 0
    private(set) var isRunning = true
    private(set) var terminateCallCount = 0
    private(set) var forceKillCallCount = 0
    private(set) var writes: [Data] = []

    init(pid: Int32, onOutput: @escaping (Data) -> Void, onTermination: @escaping (SSHProcessSession) -> Void) {
        processIdentifier = pid
        self.onOutput = onOutput
        self.onTermination = onTermination
    }

    var writtenStrings: [String] {
        writes.compactMap { String(data: $0, encoding: .utf8) }
    }

    func emit(_ text: String) {
        onOutput(Data(text.utf8))
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

private final class FakeGenericPasswordReader: GenericPasswordReading {
    struct Read: Equatable {
        var service: String
        var account: String
    }

    enum ReaderError: Error {
        case missing
    }

    private let values: [String: String]
    private(set) var reads: [Read] = []

    init(values: [String: String]) {
        self.values = values
    }

    func readGenericPassword(service: String, account: String) throws -> String {
        reads.append(Read(service: service, account: account))
        guard let value = values[service] else {
            throw ReaderError.missing
        }
        return value
    }
}
