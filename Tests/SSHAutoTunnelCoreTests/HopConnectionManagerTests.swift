import Darwin
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class HopConnectionManagerTests: XCTestCase {
    func testDirectPolicyStopDoesNotReconnectWhenOutputArrivesBeforeTermination() throws {
        try assertDirectPolicyStyleStopDoesNotReconnect(outputBeforeTermination: true)
    }

    func testDirectPolicyStopDoesNotReconnectWhenOutputArrivesAfterTermination() throws {
        try assertDirectPolicyStyleStopDoesNotReconnect(outputBeforeTermination: false)
    }

    func testSendsPasswordAndGeneratesTOTPWhenPrompted() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let keychain = FakeHopKeychain(values: [
            "password-service|alice": "secret-password",
            "totp-service|alice": "SEED"
        ])
        var generatedSeeds: [String] = []
        let profile = psiGeneralProfile()
        let manager = HopConnectionManager(
            keychain: keychain,
            processLauncher: launcher,
            healthCheck: { _ in false },
            totpGenerator: { seed in
                generatedSeeds.append(seed)
                return "654321"
            },
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)

        XCTAssertEqual(keychain.reads, [FakeHopKeychain.Read(service: "password-service", account: "alice")])
        XCTAssertTrue(generatedSeeds.isEmpty)

        session.emit("Password:")
        session.emit("Enter Your Microsoft verification code:")
        waitUntil("prompt replies are written") {
            session.writtenStrings == ["secret-password\n", "654321\n"]
        }

        XCTAssertEqual(generatedSeeds, ["SEED"])
        XCTAssertEqual(keychain.reads, [
            FakeHopKeychain.Read(service: "password-service", account: "alice"),
            FakeHopKeychain.Read(service: "totp-service", account: "alice")
        ])
    }

    func testLogsRedactedPromptAnnotationsAndOutput() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let keychain = FakeHopKeychain(values: [
            "password-service|alice": "secret-password",
            "totp-service|alice": "SEED"
        ])
        let profile = psiGeneralProfile()
        let manager = HopConnectionManager(
            keychain: keychain,
            processLauncher: launcher,
            healthCheck: { _ in false },
            totpGenerator: { _ in "654321" },
            startsHealthTimer: false
        )
        var log = ""
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
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
        session.emit("secret-password\r\nEnter Your Microsoft verification code:")
        waitUntil("TOTP reply is written") {
            session.writtenStrings == ["secret-password\n", "654321\n"]
        }
        session.emit("654321\r\n")
        waitUntil("prompt annotations are logged") {
            log.contains("TOTP sent (<redacted>)")
        }

        XCTAssertTrue(log.contains("[hop] password prompt detected"))
        XCTAssertTrue(log.contains("[hop] password sent (<redacted>)"))
        XCTAssertTrue(log.contains("[hop] TOTP prompt detected"))
        XCTAssertTrue(log.contains("[hop] TOTP sent (<redacted>)"))
        XCTAssertFalse(log.contains("secret-password"))
        XCTAssertFalse(log.contains("654321"))
    }

    func testLogsRedactSecretsSplitAcrossOutputChunks() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let keychain = FakeHopKeychain(values: [
            "password-service|alice": "secret-password",
            "totp-service|alice": "SEED"
        ])
        let profile = psiGeneralProfile(autoReconnect: false)
        let manager = HopConnectionManager(
            keychain: keychain,
            processLauncher: launcher,
            healthCheck: { _ in false },
            totpGenerator: { _ in "654321" },
            startsHealthTimer: false
        )
        var log = ""
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
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
        session.emit("password\r\nEnter Your Microsoft verification code:")
        waitUntil("TOTP reply is written") {
            session.writtenStrings == ["secret-password\n", "654321\n"]
        }
        session.emit("654")
        session.emit("321\r\n")
        manager.stop(profileID: profile.id)
        session.exit(status: SIGTERM)
        waitUntil("hop stops") {
            manager.status(for: profile.id)?.health == .stopped
        }

        XCTAssertTrue(log.contains("<redacted>"))
        XCTAssertFalse(log.contains("secret-password"))
        XCTAssertFalse(log.contains("654321"))
    }

    func testReportsHealthyAfterControlMasterCheckSucceeds() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { controlMaster in
                XCTAssertEqual(controlMaster.jumpHost, "alice@hopx.psi.ch")
                return true
            },
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        manager.runHealthCheckForTesting()

        let status = try XCTUnwrap(manager.status(for: profile.id))
        XCTAssertEqual(status.health, .healthy)
        XCTAssertEqual(status.message, "Jump host ControlMaster is ready")
        XCTAssertNotNil(manager.controlMaster(for: profile.id))
    }

    func testCompatibleProfilesPoolOneHopProcessAndDetachIndependently() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let first = psiGeneralProfile(authMode: .none)
        var second = first
        second.id = UUID()
        second.name = "PSI General second route"
        second.host = "hepserver.psi.ch"
        second.localSocksPort = 1183
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            startsHealthTimer: false
        )

        manager.start(profile: first)
        waitUntil("first shared hop starts") {
            manager.status(for: first.id)?.message == "SSH hop process started"
        }
        manager.start(profile: second)
        waitUntil("second profile shares hop") {
            manager.status(for: second.id)?.message.contains("Sharing hop ControlMaster") == true
        }
        manager.runHealthCheckForTesting()

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: first.id)?.health, .healthy)
        XCTAssertEqual(manager.status(for: second.id)?.health, .healthy)
        XCTAssertEqual(manager.controlMaster(for: first.id)?.controlPath, manager.controlMaster(for: second.id)?.controlPath)

        manager.stop(profileID: second.id)
        waitUntil("second profile detaches") {
            manager.status(for: second.id)?.health == .stopped
        }
        XCTAssertTrue(try XCTUnwrap(launcher.sessions.first).isRunning)
        XCTAssertEqual(manager.status(for: first.id)?.health, .healthy)
    }

    func testPooledHopRecoveryLaunchesOnlyOneProcessAndPausesAllProfilesOffline() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let first = psiGeneralProfile(authMode: .none)
        var second = first
        second.id = UUID()
        second.name = "PSI General second route"
        second.host = "hepserver.psi.ch"
        second.localSocksPort = 1183
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            attemptLedger: SSHConnectionAttemptLedger(limit: 100, window: 600),
            reconnectDelay: { _ in 0.02 },
            processExitObservationDelay: 0,
            startsHealthTimer: false
        )

        manager.start(profile: first)
        waitUntil("first pooled hop starts") { launcher.sessions.count == 1 }
        manager.start(profile: second)
        waitUntil("second profile joins pooled hop") {
            manager.status(for: second.id)?.message.contains("Sharing hop ControlMaster") == true
        }
        manager.runHealthCheckForTesting()

        manager.updateNetworkPathState(.unsatisfied)
        launcher.sessions[0].exit(status: 255)
        waitUntil("all pooled profiles wait for network") {
            manager.status(for: first.id)?.message.contains("Waiting for network") == true
                && manager.status(for: second.id)?.message.contains("Waiting for network") == true
        }
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(launcher.sessions.count, 1)

        manager.updateNetworkPathState(.satisfied)
        manager.updateNetworkPathState(.satisfied)
        waitUntil("pooled hop resumes once") { launcher.sessions.count == 2 }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 2)
        XCTAssertEqual(manager.status(for: first.id)?.health, .reconnecting)
        XCTAssertEqual(manager.status(for: second.id)?.health, .reconnecting)
    }

    func testProfilesWithIncompatiblePoliciesDoNotShareEndpoint() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let first = psiGeneralProfile(authMode: .none)
        var second = first
        second.id = UUID()
        second.name = "Incompatible"
        second.hostKeyPolicy = .strict
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            startsHealthTimer: false
        )

        manager.start(profile: first)
        waitUntil("first hop starts") {
            manager.status(for: first.id)?.message == "SSH hop process started"
        }
        manager.start(profile: second)
        waitUntil("incompatible profile fails") {
            manager.status(for: second.id)?.health == .failed
        }

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: second.id)?.issue?.code, .incompatibleHopConfiguration)
        XCTAssertTrue(try XCTUnwrap(launcher.sessions.first).isRunning)
    }

    func testTier3HopWaitsForReadyMarkerAfterControlMasterCheckSucceeds() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = tier3Profile(authMode: .none)
        let controlMaster = try JumpHostControlMasterFactory.make(for: profile)
        try? FileManager.default.removeItem(at: controlMaster.directory)
        defer {
            try? FileManager.default.removeItem(at: controlMaster.directory)
        }
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            initialReadinessGracePeriod: 60,
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        manager.runHealthCheckForTesting()
        XCTAssertEqual(manager.status(for: profile.id)?.health, .connecting)
        XCTAssertEqual(manager.status(for: profile.id)?.message, "Waiting for SSH authentication and jump host setup prompt")

        try XCTUnwrap(launcher.sessions.first).emit("Options (choose number):\n#? ")
        manager.runHealthCheckForTesting()

        XCTAssertEqual(manager.status(for: profile.id)?.health, .healthy)
    }

    func testUnexpectedExitReconnectsWhenEnabled() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "first start")
        let secondStart = expectation(description: "second start")
        var starts = 0
        manager.onStatusChange = { status in
            guard status.profileID == profile.id,
                  status.message == "SSH hop process started" || status.message.contains("Automatic hop reconnect attempt") else { return }
            starts += 1
            if starts == 1 {
                firstStart.fulfill()
            } else if starts == 2 {
                secondStart.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)
        manager.runHealthCheckForTesting()
        XCTAssertEqual(manager.status(for: profile.id)?.health, .healthy)
        try XCTUnwrap(launcher.sessions.first).exit(status: 255)
        wait(for: [secondStart], timeout: 1)

        XCTAssertEqual(launcher.sessions.count, 2)
        XCTAssertEqual(manager.status(for: profile.id)?.health, .reconnecting)
    }

    func testInitialHopAuthenticationFailureNeverReconnects() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            reconnectDelay: { _ in 0.01 },
            processExitObservationDelay: 0,
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("initial hop starts") { launcher.sessions.count == 1 }
        let session = try XCTUnwrap(launcher.sessions.first)
        session.emit("Permission denied, please try again.\r\n")
        session.exit(status: 255)

        waitUntil("hop authentication failure is terminal") {
            manager.status(for: profile.id)?.health == .failed
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertTrue(manager.status(for: profile.id)?.message.contains("not retryable") == true)
    }

    func testOfflineHopReconnectWaitsWithoutLaunchingAndResumesExactlyOnce() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            reconnectDelay: { _ in 0.02 },
            processExitObservationDelay: 0,
            startsHealthTimer: false
        )

        manager.start(profile: profile)
        waitUntil("initial hop starts") { launcher.sessions.count == 1 }
        manager.runHealthCheckForTesting()
        manager.updateNetworkPathState(.requiresConnection)
        launcher.sessions[0].exit(status: 255)
        waitUntil("offline hop reconnect is paused") {
            manager.status(for: profile.id)?.message.contains("Waiting for network") == true
        }
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertEqual(launcher.sessions.count, 1)

        manager.updateNetworkPathState(.satisfied)
        waitUntil("offline hop reconnect resumes") { launcher.sessions.count == 2 }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(launcher.sessions.count, 2)
    }

    func testReconnectAttemptLimitStopsUnexpectedExitReconnects() throws {
        let launcher = FakeHopSSHProcessLauncher()
        var profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        profile.curatedSSHOptions.maxReconnectAttempts = 0
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        manager.runHealthCheckForTesting()
        try XCTUnwrap(launcher.sessions.first).exit(status: 255)
        waitUntil("hop reconnect limit is reported") {
            manager.status(for: profile.id)?.message.contains("Automatic hop reconnect stopped") == true
        }

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: profile.id)?.health, .failed)
    }

    func testStopAllWaitingForceKillsStubbornHopBeforeReturning() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
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
        XCTAssertEqual(manager.status(for: profile.id)?.health, .stopped)
        XCTAssertEqual(launcher.sessions.count, 1)
    }

    func testManualStopWaitsForHopProcessTerminationBeforeReportingStopped() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            processExitObservationDelay: 0,
            stopForceKillDelay: 1,
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)
        session.exitsOnTerminate = false

        manager.stop(profileID: profile.id)
        waitUntil("hop enters stopping") {
            manager.status(for: profile.id)?.health == .stopping
        }

        XCTAssertEqual(manager.status(for: profile.id)?.pid, session.processIdentifier)
        XCTAssertEqual(session.forceKillCallCount, 0)

        session.exit(status: SIGTERM)
        waitUntil("hop stops") {
            manager.status(for: profile.id)?.health == .stopped
        }

        XCTAssertEqual(session.forceKillCallCount, 0)
    }

    private func assertDirectPolicyStyleStopDoesNotReconnect(outputBeforeTermination: Bool) throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            reconnectDelay: { _ in 0.01 },
            processExitObservationDelay: 0,
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)
        session.exitsOnTerminate = false

        manager.stop(profileID: profile.id)
        waitUntil("hop enters stopping") {
            manager.status(for: profile.id)?.health == .stopping
        }
        if outputBeforeTermination {
            session.emit("Connection closed by remote host\r\n")
        }
        session.exit(status: SIGTERM)
        if !outputBeforeTermination {
            session.emit("Connection closed by remote host\r\n")
        }
        waitUntil("hop stops") {
            manager.status(for: profile.id)?.health == .stopped
        }
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: profile.id)?.health, .stopped)
    }

    func testManualStopForceKillsStubbornHopBeforeReportingStopped() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            processExitObservationDelay: 0,
            stopForceKillDelay: 0.01,
            stopVerificationDelay: 0.01,
            startsHealthTimer: false
        )
        let started = expectation(description: "hop process started")
        manager.onStatusChange = { status in
            if status.profileID == profile.id, status.message == "SSH hop process started" {
                started.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [started], timeout: 1)
        let session = try XCTUnwrap(launcher.sessions.first)
        session.exitsOnTerminate = false

        manager.stop(profileID: profile.id)
        waitUntil("hop enters stopping") {
            manager.status(for: profile.id)?.health == .stopping
        }
        waitUntil("stubborn hop is force killed") {
            session.forceKillCallCount == 1
        }
        waitUntil("hop stops after force kill") {
            manager.status(for: profile.id)?.health == .stopped
        }

        XCTAssertEqual(session.terminateCallCount, 1)
        XCTAssertFalse(session.isRunning)
    }

    func testExistingSessionMessageStopsReconnectAndMarksFailure() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let expectedHost = profile.jumpHost ?? ""
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "hop process started")
        let statusFailed = expectation(description: "hop marked failed")
        var statusMessages: [String] = []

        manager.onStatusChange = { status in
            guard status.profileID == profile.id else { return }
            if status.message == "SSH hop process started" {
                firstStart.fulfill()
            }
            if status.health == .failed {
                statusMessages.append(status.message)
                statusFailed.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)

        let session = try XCTUnwrap(launcher.sessions.first)
        session.emit("You already have an existing session to hopx!")
        session.exit(status: 0)

        wait(for: [statusFailed], timeout: 1)
        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: profile.id)?.health, .failed)
        XCTAssertTrue(statusMessages.last?.contains("existing hop session is already active on \(expectedHost)") == true)
        assertNoReconnectAttempt(launcher, expectedCount: 1)
    }

    func testExistingSessionConflictWorksForOtherHopHostAndNoReconnect() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = tier3Profile(authMode: .none, autoReconnect: true)
        let expectedHost = profile.jumpHost ?? ""
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "hop process started")
        let statusFailed = expectation(description: "hop marked failed")
        var failedMessages: [String] = []

        manager.onStatusChange = { status in
            guard status.profileID == profile.id else { return }
            if status.message == "SSH hop process started" {
                firstStart.fulfill()
            }
            if status.health == .failed {
                failedMessages.append(status.message)
                statusFailed.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)

        let session = try XCTUnwrap(launcher.sessions.first)
        session.emit("Multiple sessions to this systems for the same user are not possible")
        session.exit(status: 0)

        wait(for: [statusFailed], timeout: 1)
        XCTAssertEqual(launcher.sessions.count, 1)
        XCTAssertEqual(manager.status(for: profile.id)?.health, .failed)
        XCTAssertTrue(failedMessages.last?.contains("existing hop session is already active on \(expectedHost)") == true)
        assertNoReconnectAttempt(launcher, expectedCount: 1)
    }

    func testExistingSessionConflictDetectedAcrossOutputChunks() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let expectedHost = profile.jumpHost ?? ""
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "hop process started")
        let statusFailed = expectation(description: "hop marked failed")
        var failedMessages: [String] = []

        manager.onStatusChange = { status in
            guard status.profileID == profile.id else { return }
            if status.message == "SSH hop process started" {
                firstStart.fulfill()
            }
            if status.health == .failed {
                failedMessages.append(status.message)
                statusFailed.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)

        let session = try XCTUnwrap(launcher.sessions.first)
        session.emit("You already have an existing session")
        session.emit(" to")
        session.emit(" hopx!")
        session.exit(status: 0)

        wait(for: [statusFailed], timeout: 1)
        XCTAssertEqual(manager.status(for: profile.id)?.health, .failed)
        XCTAssertTrue(failedMessages.last?.contains("existing hop session is already active on \(expectedHost)") == true)
        assertNoReconnectAttempt(launcher, expectedCount: 1)
    }

    func testExistingSessionOutputAfterTerminationStillCancelsReconnect() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let expectedHost = profile.jumpHost ?? ""
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in false },
            reconnectDelay: { _ in 0.01 },
            processExitObservationDelay: 0.02,
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "hop process started")
        let statusFailed = expectation(description: "hop marked failed")
        var failedMessages: [String] = []

        manager.onStatusChange = { status in
            guard status.profileID == profile.id else { return }
            if status.message == "SSH hop process started" {
                firstStart.fulfill()
            }
            if status.health == .failed {
                failedMessages.append(status.message)
                statusFailed.fulfill()
            }
        }

        manager.start(profile: profile)
        wait(for: [firstStart], timeout: 1)

        let session = try XCTUnwrap(launcher.sessions.first)
        session.exit(status: 0)
        session.emit("You already have an existing session to hopx!")

        wait(for: [statusFailed], timeout: 1)
        XCTAssertEqual(manager.status(for: profile.id)?.health, .failed)
        XCTAssertTrue(failedMessages.last?.contains("existing hop session is already active on \(expectedHost)") == true)
        assertNoReconnectAttempt(launcher, expectedCount: 1, timeout: 0.15)
    }

    func testVerboseReconnectsStayVerboseUntilNormalStartReplaces() throws {
        let launcher = FakeHopSSHProcessLauncher()
        let profile = psiGeneralProfile(authMode: .none, autoReconnect: true)
        let manager = HopConnectionManager(
            processLauncher: launcher,
            healthCheck: { _ in true },
            reconnectDelay: { _ in 0.01 },
            startsHealthTimer: false
        )
        let firstStart = expectation(description: "first verbose start")
        let secondStart = expectation(description: "second verbose start")
        let thirdStart = expectation(description: "normal replacement start")
        var starts = 0
        manager.onStatusChange = { status in
            guard status.profileID == profile.id,
                  status.message == "SSH hop process started" || status.message.contains("Automatic hop reconnect attempt") else { return }
            starts += 1
            if starts == 1 {
                firstStart.fulfill()
            } else if starts == 2 {
                secondStart.fulfill()
            } else if starts == 3 {
                thirdStart.fulfill()
            }
        }

        manager.start(profile: profile, options: SSHLaunchOptions(verbose: true))
        wait(for: [firstStart], timeout: 1)
        XCTAssertTrue(try XCTUnwrap(launcher.commands.first).arguments.contains("-vvv"))
        manager.runHealthCheckForTesting()
        XCTAssertEqual(manager.status(for: profile.id)?.health, .healthy)

        try XCTUnwrap(launcher.sessions.first).exit(status: 255)
        wait(for: [secondStart], timeout: 1)
        XCTAssertTrue(try XCTUnwrap(launcher.commands.dropFirst().first).arguments.contains("-vvv"))

        manager.start(profile: profile, options: .standard)
        wait(for: [thirdStart], timeout: 1)
        XCTAssertFalse(try XCTUnwrap(launcher.commands.dropFirst(2).first).arguments.contains("-vvv"))
    }

    private func psiGeneralProfile(authMode: TunnelAuthMode = .passwordAndTOTP, autoReconnect: Bool = true) -> TunnelProfile {
        TunnelProfile(
            name: "PSI General",
            host: "login.psi.ch",
            user: "alice",
            localSocksPort: 1083,
            jumpHost: "alice@hopx.psi.ch",
            authMode: authMode,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "password-service",
                totpService: "totp-service"
            ),
            autoReconnect: autoReconnect
        )
    }

    private func tier3Profile(authMode: TunnelAuthMode = .passwordAndTOTP, autoReconnect: Bool = true) -> TunnelProfile {
        TunnelProfile(
            name: "PSI CMS Tier-3",
            host: "t3ui07.psi.ch",
            user: "alice",
            localSocksPort: 1082,
            jumpHost: "alice@t3hop01.psi.ch",
            authMode: authMode,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "password-service",
                totpService: "totp-service"
            ),
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

    private func assertNoReconnectAttempt(
        _ launcher: FakeHopSSHProcessLauncher,
        expectedCount: Int,
        timeout: TimeInterval = 0.2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if launcher.sessions.count != expectedCount {
                XCTFail("Unexpected reconnect attempt", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(launcher.sessions.count, expectedCount, file: file, line: line)
    }
}

private final class FakeHopSSHProcessLauncher: SSHProcessLaunching {
    private var nextPID: Int32 = 20_000
    private let lock = NSLock()
    private(set) var commands: [SSHCommand] = []
    private(set) var sessions: [FakeHopSSHProcessSession] = []

    func launch(
        command: SSHCommand,
        terminalFileDescriptor: Int32?,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession {
        lock.lock()
        defer { lock.unlock() }
        commands.append(command)
        let session = FakeHopSSHProcessSession(pid: nextPID, onOutput: onOutput, onTermination: onTermination)
        nextPID += 1
        sessions.append(session)
        return session
    }
}

private final class FakeHopSSHProcessSession: SSHProcessSession {
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

private final class FakeHopKeychain: GenericPasswordReading {
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
        guard let value = values["\(service)|\(account)"] else {
            throw ReaderError.missing
        }
        return value
    }
}
