import Darwin
import XCTest
@testable import SSHAutoTunnelCore

final class TunnelManagerProcessTests: XCTestCase {
    func testDirectPolicyStopDoesNotReconnectWhenOutputArrivesBeforeTermination() throws {
        try assertDirectPolicyStyleStopDoesNotReconnect(outputBeforeTermination: true)
    }

    func testDirectPolicyStopDoesNotReconnectWhenOutputArrivesAfterTermination() throws {
        try assertDirectPolicyStyleStopDoesNotReconnect(outputBeforeTermination: false)
    }

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
        waitUntil("tunnel enters stopping") {
            manager.status(for: profile.id).health == .stopping
        }
        session.exit(status: SIGTERM)
        wait(for: [stopped], timeout: 1)
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(manager.status(for: profile.id).health, .stopped)
        XCTAssertEqual(launcher.sessions.count, 1)
    }

    private func assertDirectPolicyStyleStopDoesNotReconnect(outputBeforeTermination: Bool) throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            reconnectDelay: { _ in 0.01 },
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
        session.exitsOnTerminate = false

        manager.stop(profileID: profile.id)
        waitUntil("tunnel enters stopping") {
            manager.status(for: profile.id).health == .stopping
        }
        if outputBeforeTermination {
            session.emit("Connection closed by remote host\r\n")
        }
        session.exit(status: SIGTERM)
        if !outputBeforeTermination {
            session.emit("Connection closed by remote host\r\n")
        }
        waitUntil("tunnel stops") {
            manager.status(for: profile.id).health == .stopped
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: profile.id).health, .stopped)
    }

    func testManualStopRemovesRegistryOnlyAfterProcessTerminates() throws {
        let launcher = FakeSSHProcessLauncher()
        let registry = FakeTunnelProcessRegistry()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            tunnelProcessRegistry: registry,
            processExitOutputSettleDelay: 0,
            stopForceKillDelay: 1,
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
        session.exitsOnTerminate = false

        manager.stop(profileID: profile.id)
        waitUntil("tunnel enters stopping") {
            manager.status(for: profile.id).health == .stopping
        }

        XCTAssertEqual(manager.status(for: profile.id).pid, session.processIdentifier)
        XCTAssertTrue(registry.removals.isEmpty)
        XCTAssertEqual(session.forceKillCallCount, 0)

        session.exit(status: SIGTERM)
        waitUntil("tunnel stops") {
            manager.status(for: profile.id).health == .stopped
        }

        XCTAssertEqual(registry.removals.map(\.pid), [session.processIdentifier])
        XCTAssertEqual(session.forceKillCallCount, 0)
    }

    func testManualStopForceKillsStubbornTunnelBeforeReportingStopped() throws {
        let launcher = FakeSSHProcessLauncher()
        let registry = FakeTunnelProcessRegistry()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            tunnelProcessRegistry: registry,
            processExitOutputSettleDelay: 0,
            stopForceKillDelay: 0.01,
            stopVerificationDelay: 0.01,
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
        session.exitsOnTerminate = false

        manager.stop(profileID: profile.id)
        waitUntil("tunnel enters stopping") {
            manager.status(for: profile.id).health == .stopping
        }
        waitUntil("stubborn tunnel is force killed") {
            session.forceKillCallCount == 1
        }
        waitUntil("tunnel stops after force kill") {
            manager.status(for: profile.id).health == .stopped
        }

        XCTAssertEqual(session.terminateCallCount, 1)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(registry.removals.map(\.pid), [session.processIdentifier])
    }

    func testStopAllWaitingForceKillsStubbornTunnelBeforeReturning() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            reconnectDelay: { _ in 0.01 },
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
        session.exitsOnTerminate = false

        let didExit = manager.stopAllWaiting(upTo: 0.2, forceKillAfter: 0.01)

        XCTAssertTrue(didExit)
        XCTAssertEqual(session.terminateCallCount, 1)
        XCTAssertEqual(session.forceKillCallCount, 1)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(manager.status(for: profile.id).health, .stopped)
        XCTAssertEqual(launcher.sessions.count, 1)
    }

    func testUnexpectedExitReconnectsWhenEnabled() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in true },
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
        XCTAssertEqual(manager.status(for: profile.id).health, .healthy)
        try XCTUnwrap(launcher.sessions.first).exit(status: 255)
        wait(for: [secondStart], timeout: 1)

        XCTAssertEqual(launcher.sessions.count, 2)
        XCTAssertEqual(manager.status(for: profile.id).health, .connecting)
    }

    func testReconnectAttemptLimitStopsUnexpectedExitReconnects() throws {
        let launcher = FakeSSHProcessLauncher()
        var profile = testProfile(autoReconnect: true)
        profile.curatedSSHOptions.maxReconnectAttempts = 0
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in true },
            reconnectDelay: { _ in 0.01 },
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
        try XCTUnwrap(launcher.sessions.first).exit(status: 255)
        waitUntil("reconnect limit is reported") {
            manager.status(for: profile.id).message.contains("Automatic reconnect stopped")
        }

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: profile.id).health, .failed)
    }

    func testInitialAuthenticationFailureNeverReconnects() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            reconnectDelay: { _ in 0.01 },
            processExitOutputSettleDelay: 0,
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("initial tunnel starts") { launcher.sessions.count == 1 }
        let session = try XCTUnwrap(launcher.sessions.first)
        session.emit("Permission denied, please try again.\r\n")
        session.exit(status: 255)

        waitUntil("authentication failure is terminal") {
            manager.status(for: profile.id).health == .failed
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("not retryable"))
    }

    func testAutomaticReconnectStopsAfterThreeFailedAttempts() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in true },
            attemptLedger: SSHConnectionAttemptLedger(limit: 100, window: 600),
            reconnectDelay: { _ in 0.01 },
            processExitOutputSettleDelay: 0,
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("initial tunnel starts") { launcher.sessions.count == 1 }
        manager.runHealthCheckForTesting()
        launcher.sessions[0].exit(status: 255)

        for expectedCount in 2...4 {
            waitUntil("automatic reconnect attempt \(expectedCount - 1) starts") {
                launcher.sessions.count == expectedCount
            }
            launcher.sessions[expectedCount - 1].exit(status: 255)
        }

        waitUntil("automatic reconnect reaches terminal state") {
            manager.status(for: profile.id).health == .failed
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 4)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("stopped after 3 failed attempts"))
    }

    func testAuthenticationFailureOnAutomaticAttemptStopsCampaignWithLateOutput() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in true },
            attemptLedger: SSHConnectionAttemptLedger(limit: 100, window: 600),
            reconnectDelay: { _ in 0.01 },
            processExitOutputSettleDelay: 0.03,
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("initial tunnel starts") { launcher.sessions.count == 1 }
        manager.runHealthCheckForTesting()
        launcher.sessions[0].exit(status: 255)
        waitUntil("automatic reconnect starts") { launcher.sessions.count == 2 }

        launcher.sessions[1].exit(status: 255)
        launcher.sessions[1].emit("Permission denied, please try again.\r\n")
        waitUntil("automatic authentication failure stops") {
            manager.status(for: profile.id).health == .failed
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 2)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("not retryable"))
    }

    func testReconnectAttemptsResetOnlyAfterStableHealthyInterval() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var scheduledAttempts: [Int] = []
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in true },
            attemptLedger: SSHConnectionAttemptLedger(limit: 100, window: 600),
            reconnectDelay: { attempt in
                scheduledAttempts.append(attempt)
                return 0.01
            },
            healthyResetInterval: 300,
            processExitOutputSettleDelay: 0,
            now: { currentDate },
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("initial tunnel starts") { launcher.sessions.count == 1 }
        manager.runHealthCheckForTesting()
        launcher.sessions[0].exit(status: 255)
        waitUntil("first reconnect starts") { launcher.sessions.count == 2 }

        manager.runHealthCheckForTesting()
        currentDate = currentDate.addingTimeInterval(299)
        manager.runHealthCheckForTesting()
        launcher.sessions[1].exit(status: 255)
        waitUntil("second reconnect starts") { launcher.sessions.count == 3 }

        manager.runHealthCheckForTesting()
        currentDate = currentDate.addingTimeInterval(300)
        manager.runHealthCheckForTesting()
        launcher.sessions[2].exit(status: 255)
        waitUntil("post-stability reconnect starts") { launcher.sessions.count == 4 }

        XCTAssertEqual(scheduledAttempts, [1, 2, 1])
    }

    func testStartUsesAllocatedRuntimeSocksPortWithoutChangingProfile() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        var allocatorCalls: [(preferred: Int, reserved: Set<Int>)] = []
        let manager = TunnelManager(
            processLauncher: launcher,
            socksPortAllocator: { preferred, reserved in
                allocatorCalls.append((preferred, reserved))
                return RuntimeSocksPortAllocation(port: 1100, usedPreferredPort: false)
            },
            startsHealthTimer: false
        )
        let started = expectation(description: "started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile, reservedSocksPorts: [1083, 1098])
        wait(for: [started], timeout: 1)

        XCTAssertEqual(allocatorCalls.count, 1)
        XCTAssertEqual(allocatorCalls.first?.preferred, 1099)
        XCTAssertEqual(allocatorCalls.first?.reserved, [1083, 1098])
        XCTAssertEqual(try XCTUnwrap(launcher.commands.first).dynamicForwardPort, 1100)
        XCTAssertEqual(profile.localSocksPort, 1099)
        XCTAssertEqual(manager.status(for: profile.id).effectiveLocalSocksPort, 1100)
    }

    func testStartRecordsLaunchedTunnelProcess() throws {
        let launcher = FakeSSHProcessLauncher()
        let registry = FakeTunnelProcessRegistry()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            socksPortAllocator: { preferred, _ in RuntimeSocksPortAllocation(port: preferred, usedPreferredPort: true) },
            tunnelProcessRegistry: registry,
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

        let record = try XCTUnwrap(registry.upserts.first)
        XCTAssertEqual(record.profileID, profile.id)
        XCTAssertEqual(record.configuredSocksPort, 1099)
        XCTAssertEqual(record.effectiveSocksPort, 1099)
        XCTAssertEqual(record.pid, 10_000)
        XCTAssertEqual(record.arguments, try XCTUnwrap(launcher.commands.first).arguments)
    }

    func testStartReclaimsStalePreferredPortBeforeLaunching() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        var didReclaim = false
        let reclaimer = FakeTunnelProcessReclaimer(
            result: TunnelProcessReclaimResult(
                reclaimed: [TunnelProcessReclaimedProcess(pid: 42, port: 1099, reason: "matching stale SSH tunnel listener")]
            ),
            onReclaim: { _, _, _ in didReclaim = true }
        )
        let manager = TunnelManager(
            processLauncher: launcher,
            socksPortAllocator: { preferred, _ in RuntimeSocksPortAllocation(port: preferred, usedPreferredPort: true) },
            preferredSocksPortAvailable: { _ in didReclaim },
            tunnelProcessReclaimer: reclaimer,
            startsHealthTimer: false
        )
        var log = ""
        let started = expectation(description: "started")
        manager.onLog = { _, text in log += text }
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)

        XCTAssertEqual(try XCTUnwrap(launcher.commands.first).dynamicForwardPort, 1099)
        XCTAssertTrue(log.contains("reclaimed stale SSH tunnel pid 42 on 127.0.0.1:1099"))
        XCTAssertEqual(reclaimer.calls.map(\.configuredPort), [1099])
    }

    func testStartFailsWhenPreferredPortHasUnsafeBlocker() throws {
        let launcher = FakeSSHProcessLauncher()
        let keychain = FakeGenericPasswordReader(values: ["password-service": "secret-password"])
        let profile = TunnelProfile(
            name: "Test",
            host: "ssh.example.org",
            localSocksPort: 1099,
            authMode: .password,
            keychain: KeychainReference(account: "alice", passwordService: "password-service")
        )
        let reclaimer = FakeTunnelProcessReclaimer(
            result: TunnelProcessReclaimResult(
                blockers: [
                    TunnelProcessReclaimBlocker(
                        pid: 44,
                        port: 1099,
                        reason: "listener is not a verified stale SSH AutoTunnel process"
                    )
                ]
            )
        )
        let manager = TunnelManager(
            keychain: keychain,
            processLauncher: launcher,
            tunnelProcessReclaimer: reclaimer,
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("unsafe blocker is reported") {
            manager.status(for: profile.id).health == .failed
        }

        XCTAssertTrue(keychain.reads.isEmpty)
        XCTAssertTrue(launcher.commands.isEmpty)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("Local SOCKS port 1099 is already in use"))
        XCTAssertTrue(manager.status(for: profile.id).message.contains("pid 44"))
    }

    func testStartFailsWhenPreferredPortRemainsUnavailableAfterReclaim() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            preferredSocksPortAvailable: { _ in false },
            tunnelProcessReclaimer: FakeTunnelProcessReclaimer(),
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("occupied preferred port is reported") {
            manager.status(for: profile.id).health == .failed
        }

        XCTAssertTrue(launcher.commands.isEmpty)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("refusing to switch to an alternate SOCKS port"))
    }

    func testStartFailsBeforeReadingKeychainWhenNoRuntimeSocksPortIsAvailable() throws {
        let launcher = FakeSSHProcessLauncher()
        let keychain = FakeGenericPasswordReader(values: ["password-service": "secret-password"])
        let profile = TunnelProfile(
            name: "Test",
            host: "ssh.example.org",
            localSocksPort: 1099,
            authMode: .password,
            keychain: KeychainReference(account: "alice", passwordService: "password-service")
        )
        let manager = TunnelManager(
            keychain: keychain,
            processLauncher: launcher,
            socksPortAllocator: { preferred, _ in
                throw RuntimeSocksPortAllocationError(preferredPort: preferred)
            },
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("port allocation failure is reported") {
            manager.status(for: profile.id).health == .failed
        }

        XCTAssertTrue(keychain.reads.isEmpty)
        XCTAssertTrue(launcher.commands.isEmpty)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("Could not find an available local SOCKS port"))
    }

    func testHealthProbeUsesAllocatedRuntimeSocksPort() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        var probedPorts: [Int] = []
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { port in
                probedPorts.append(port)
                return port == 1100
            },
            socksPortAllocator: { _, _ in RuntimeSocksPortAllocation(port: 1100, usedPreferredPort: false) },
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

        XCTAssertEqual(probedPorts, [1100])
        XCTAssertEqual(manager.status(for: profile.id).health, .healthy)
        XCTAssertEqual(manager.status(for: profile.id).effectiveLocalSocksPort, 1100)
    }

    func testAppOwnedForwardingFailureRetriesOnceWithAlternateRuntimePort() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        var allocatedPorts = [1099, 1100]
        let manager = TunnelManager(
            processLauncher: launcher,
            socksPortAllocator: { _, reserved in
                let next = allocatedPorts.removeFirst()
                XCTAssertFalse(reserved.contains(next))
                return RuntimeSocksPortAllocation(port: next, usedPreferredPort: next == 1099)
            },
            reconnectDelay: { _ in 0.01 },
            processExitOutputSettleDelay: 0,
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "first start")
        let secondStart = expectation(description: "second start")
        var starts = 0
        manager.onStatusChange = { status in
            guard status.profileID == profile.id, status.message == "SSH process started" else { return }
            starts += 1
            if starts == 1 {
                firstStart.fulfill()
            } else if starts == 2 {
                secondStart.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)
        session.emit(forwardingFailureTranscript(port: 1099))
        session.exit(status: 255)
        wait(for: [secondStart], timeout: 1)

        XCTAssertEqual(launcher.commands.map(\.dynamicForwardPort), [1099, 1100])
        XCTAssertEqual(manager.status(for: profile.id).health, .connecting)
        XCTAssertEqual(manager.status(for: profile.id).effectiveLocalSocksPort, 1100)
    }

    func testAppOwnedForwardingFailureRetrySkipsPreferredPortReclaim() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let reclaimer = FakeTunnelProcessReclaimer()
        var allocatedPorts = [1099, 1100]
        let manager = TunnelManager(
            processLauncher: launcher,
            socksPortAllocator: { _, _ in
                let next = allocatedPorts.removeFirst()
                return RuntimeSocksPortAllocation(port: next, usedPreferredPort: next == 1099)
            },
            tunnelProcessReclaimer: reclaimer,
            reconnectDelay: { _ in 0.01 },
            processExitOutputSettleDelay: 0,
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "first start")
        let secondStart = expectation(description: "second start")
        var starts = 0
        manager.onStatusChange = { status in
            guard status.profileID == profile.id, status.message == "SSH process started" else { return }
            starts += 1
            if starts == 1 {
                firstStart.fulfill()
            } else if starts == 2 {
                secondStart.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)
        session.emit(forwardingFailureTranscript(port: 1099))
        session.exit(status: 255)
        wait(for: [secondStart], timeout: 1)

        XCTAssertEqual(launcher.commands.map(\.dynamicForwardPort), [1099, 1100])
        XCTAssertEqual(reclaimer.calls.map(\.configuredPort), [1099])
    }

    func testLocalForwardingFailureDoesNotReconnectWhenOutputArrivesBeforeTermination() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            reconnectDelay: { _ in 0.01 },
            processExitOutputSettleDelay: 0,
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

        session.emit(cernForwardingFailureTranscript)
        session.exit(status: 255)
        waitUntil("forwarding failure is marked failed") {
            manager.status(for: profile.id).health == .failed
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("port 12345 is already in use"))
    }

    func testLocalForwardingFailureDoesNotReconnectWhenOutputArrivesAfterTermination() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        let manager = TunnelManager(
            processLauncher: launcher,
            reconnectDelay: { _ in 0.01 },
            processExitOutputSettleDelay: 0.05,
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

        session.exit(status: 255)
        session.emit(cernForwardingFailureTranscript)
        waitUntil("late forwarding failure is marked failed") {
            manager.status(for: profile.id).health == .failed
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertTrue(manager.status(for: profile.id).message.contains("port 12345 is already in use"))
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
            "SSH exited with status 255: Permission denied, please try again.; authentication or host-key failure is not retryable; automatic reconnect stopped and no more attempts will be made"
        )
    }

    func testRepeatedHealthFailureRestartsTunnel() throws {
        let launcher = FakeSSHProcessLauncher()
        let profile = testProfile(autoReconnect: true)
        var probeSucceeds = true
        let manager = TunnelManager(
            processLauncher: launcher,
            socks5Probe: { _ in probeSucceeds },
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
        XCTAssertEqual(manager.status(for: profile.id).health, .healthy)
        probeSucceeds = false

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

    func testLogsRedactSecretsSplitAcrossOutputChunks() throws {
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
            ),
            autoReconnect: false
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
        session.emit("secret-")
        session.emit("password\r\nVerification code:")
        waitUntil("TOTP reply is written") {
            session.writtenStrings == ["secret-password\n", "654321\n"]
        }
        session.emit("654")
        session.emit("321\r\n")
        manager.stop(profileID: profile.id)
        session.exit(status: SIGTERM)
        waitUntil("tunnel stops") {
            manager.status(for: profile.id).health == .stopped
        }

        XCTAssertTrue(log.contains("<redacted>"))
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

private let cernForwardingFailureTranscript = """
(clange@lxtunnel.cern.ch) Your 2nd factor (clange): <redacted>
bind [127.0.0.1]:12345: Address already in use\r
channel_setup_fwd_listener_tcpip: cannot listen to port: 12345\r
Could not request local forwarding.\r
"""

private func forwardingFailureTranscript(port: Int) -> String {
    """
    bind [127.0.0.1]:\(port): Address already in use\r
    channel_setup_fwd_listener_tcpip: cannot listen to port: \(port)\r
    Could not request local forwarding.\r
    """
}

private extension SSHCommand {
    var dynamicForwardPort: Int? {
        guard let index = arguments.firstIndex(of: "-D"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
            .split(separator: ":")
            .last
            .flatMap { Int($0) }
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
    var exitsOnTerminate = true
    var exitsOnForceKill = true

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
        terminationStatus = SIGTERM
        if exitsOnTerminate {
            isRunning = false
        }
    }

    func forceKill() {
        forceKillCallCount += 1
        terminationStatus = SIGKILL
        if exitsOnForceKill {
            isRunning = false
        }
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

private final class FakeTunnelProcessRegistry: TunnelProcessRecording {
    private(set) var upserts: [TunnelProcessRecord] = []
    private(set) var removals: [(profileID: UUID, pid: Int32)] = []

    func records() -> [TunnelProcessRecord] { upserts }

    func records(for profileID: UUID) -> [TunnelProcessRecord] {
        upserts.filter { $0.profileID == profileID }
    }

    func upsert(_ record: TunnelProcessRecord) {
        upserts.append(record)
    }

    func remove(profileID: UUID, pid: Int32) {
        removals.append((profileID, pid))
    }

    func pruneInactive() {}
}

private final class FakeTunnelProcessReclaimer: TunnelProcessReclaiming {
    struct Call: Equatable {
        var profileID: UUID
        var configuredPort: Int
        var activePIDs: Set<Int32>
    }

    private let result: TunnelProcessReclaimResult
    private let onReclaim: (TunnelProfile, Int, Set<Int32>) -> Void
    private(set) var calls: [Call] = []

    init(
        result: TunnelProcessReclaimResult = TunnelProcessReclaimResult(),
        onReclaim: @escaping (TunnelProfile, Int, Set<Int32>) -> Void = { _, _, _ in }
    ) {
        self.result = result
        self.onReclaim = onReclaim
    }

    func reclaimStaleProcesses(
        for profile: TunnelProfile,
        configuredPort: Int,
        activePIDs: Set<Int32>
    ) -> TunnelProcessReclaimResult {
        calls.append(Call(profileID: profile.id, configuredPort: configuredPort, activePIDs: activePIDs))
        onReclaim(profile, configuredPort, activePIDs)
        return result
    }
}
