import Foundation
import Darwin
import XCTest
@testable import SSHAutoTunnelCore

final class InteractiveSSHSessionRunnerTests: XCTestCase {
    func testRunnerSendsPasswordAndTOTPToPromptedInteractiveSession() throws {
        let launcher = FakeInteractiveSSHProcessLauncher()
        let outputPipe = Pipe()
        let runner = InteractiveSSHSessionRunner(
            keychain: FakeInteractiveKeychain(values: [
                "password-service|alice": "secret-password",
                "totp-service|alice": "SEED"
            ]),
            processLauncher: launcher,
            totpGenerator: { seed in
                XCTAssertEqual(seed, "SEED")
                return "123456"
            }
        )
        let profile = TunnelProfile(
            name: "Interactive",
            host: "login.example.org",
            user: "alice",
            localSocksPort: 1081,
            authMode: .passwordAndTOTP,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "password-service",
                totpService: "totp-service"
            )
        )

        let runQueue = DispatchQueue(label: "interactive-runner-test")
        var runResult: Result<Int32, Error>?
        let finished = expectation(description: "runner finished")
        runQueue.async {
            runResult = Result {
                try runner.run(
                    profile: profile,
                    input: FileHandle.standardInput,
                    output: outputPipe.fileHandleForWriting,
                    errorOutput: outputPipe.fileHandleForWriting,
                    bridgeInput: false,
                    configureTerminal: false
                )
            }
            finished.fulfill()
        }

        let session = try waitForSession(launcher)
        launcher.output("Password:")
        launcher.output("One-time code:")
        session.finish(status: 0)

        wait(for: [finished], timeout: 2)
        XCTAssertEqual(try runResult?.get(), 0)
        XCTAssertEqual(session.writtenStrings, ["secret-password\n", "123456\n"])
    }

    func testRunnerUsesInteractiveHostInSSHCommand() throws {
        let launcher = FakeInteractiveSSHProcessLauncher()
        let outputPipe = Pipe()
        let runner = InteractiveSSHSessionRunner(
            keychain: FakeInteractiveKeychain(values: [:]),
            processLauncher: launcher
        )
        let profile = TunnelProfile(
            name: "Interactive",
            host: "lxtunnel.cern.ch",
            user: "alice",
            localSocksPort: 1081,
            interactiveHost: "lxplus.cern.ch"
        )

        let runQueue = DispatchQueue(label: "interactive-command-test")
        let finished = expectation(description: "runner finished")
        runQueue.async {
            _ = try? runner.run(
                profile: profile,
                input: FileHandle.standardInput,
                output: outputPipe.fileHandleForWriting,
                errorOutput: outputPipe.fileHandleForWriting,
                bridgeInput: false,
                configureTerminal: false
            )
            finished.fulfill()
        }

        let session = try waitForSession(launcher)
        session.finish(status: 0)

        wait(for: [finished], timeout: 2)
        XCTAssertEqual(launcher.command?.arguments.last, "alice@lxplus.cern.ch")
    }

    func testRunnerOpensTier3JumpHostControlMasterBeforeFinalSession() throws {
        try assertRunnerOpensJumpHostControlMasterBeforeFinalSession(
            profileName: "PSI CMS Tier-3",
            host: "t3ui07.psi.ch",
            jumpHost: "alice@t3hop01.psi.ch",
            secondFactorPrompt: "One-time code:"
        )
    }

    func testRunnerOpensPSIGeneralJumpHostControlMasterBeforeFinalSession() throws {
        try assertRunnerOpensJumpHostControlMasterBeforeFinalSession(
            profileName: "PSI General",
            host: "login.psi.ch",
            jumpHost: "alice@hopx.psi.ch",
            secondFactorPrompt: "Enter Your Microsoft verification code:"
        )
    }

    private func assertRunnerOpensJumpHostControlMasterBeforeFinalSession(
        profileName: String,
        host: String,
        jumpHost: String,
        secondFactorPrompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let launcher = FakeInteractiveSSHProcessLauncher()
        let outputPipe = Pipe()
        let runner = InteractiveSSHSessionRunner(
            keychain: FakeInteractiveKeychain(values: [
                "password-service|alice": "secret-password",
                "totp-service|alice": "SEED"
            ]),
            processLauncher: launcher,
            totpGenerator: { _ in "654321" },
            runCommand: { _, _ in }
        )
        let profile = TunnelProfile(
            name: profileName,
            host: host,
            user: "alice",
            localSocksPort: 1082,
            jumpHost: jumpHost,
            authMode: .passwordAndTOTP,
            keychain: KeychainReference(
                account: "alice",
                passwordService: "password-service",
                totpService: "totp-service"
            )
        )

        let runQueue = DispatchQueue(label: "interactive-tier3-test")
        var runResult: Result<Int32, Error>?
        let finished = expectation(description: "runner finished")
        runQueue.async {
            runResult = Result {
                try runner.run(
                    profile: profile,
                    input: FileHandle.standardInput,
                    output: outputPipe.fileHandleForWriting,
                    errorOutput: outputPipe.fileHandleForWriting,
                    bridgeInput: false,
                    configureTerminal: false
                )
            }
            finished.fulfill()
        }

        let masterSession = try waitForSession(launcher, at: 0)
        launcher.output("Password:", sessionIndex: 0)
        launcher.output(secondFactorPrompt, sessionIndex: 0)
        masterSession.finish(status: 0)

        let finalSession = try waitForSession(launcher, at: 1)
        finalSession.finish(status: 0)

        wait(for: [finished], timeout: 2)
        XCTAssertEqual(try runResult?.get(), 0, file: file, line: line)
        XCTAssertEqual(masterSession.writtenStrings, ["secret-password\n", "654321\n"], file: file, line: line)
        XCTAssertEqual(launcher.commands.first?.arguments.first, "-MNf", file: file, line: line)
        XCTAssertEqual(launcher.commands.first?.arguments.last, jumpHost, file: file, line: line)
        XCTAssertTrue(launcher.commands[1].arguments.contains { $0.hasPrefix("ProxyCommand=/usr/bin/ssh -S ") }, file: file, line: line)
        XCTAssertFalse(launcher.commands[1].arguments.contains("-J"), file: file, line: line)
        XCTAssertEqual(launcher.commands[1].arguments.last, "alice@\(host)", file: file, line: line)
    }

    private func waitForSession(_ launcher: FakeInteractiveSSHProcessLauncher, at index: Int = 0) throws -> FakeInteractiveSSHProcessSession {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let session = launcher.session(at: index) {
                return session
            }
            usleep(1_000)
        }
        return try XCTUnwrap(launcher.session(at: index))
    }
}

private final class FakeInteractiveSSHProcessLauncher: SSHProcessLaunching {
    private let lock = NSLock()
    private(set) var command: SSHCommand?
    private(set) var commands: [SSHCommand] = []
    private var onOutputs: [(Data) -> Void] = []
    private var sessions: [FakeInteractiveSSHProcessSession] = []

    func launch(
        command: SSHCommand,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession {
        lock.lock()
        defer { lock.unlock() }
        self.command = command
        self.commands.append(command)
        self.onOutputs.append(onOutput)
        let session = FakeInteractiveSSHProcessSession(onTermination: onTermination)
        self.sessions.append(session)
        return session
    }

    func session(at index: Int) -> FakeInteractiveSSHProcessSession? {
        lock.lock()
        defer { lock.unlock() }
        guard sessions.indices.contains(index) else { return nil }
        return sessions[index]
    }

    func output(_ text: String, sessionIndex: Int = 0) {
        let data = Data(text.utf8)
        lock.lock()
        let onOutput = onOutputs.indices.contains(sessionIndex) ? onOutputs[sessionIndex] : nil
        lock.unlock()
        onOutput?(data)
    }
}

private final class FakeInteractiveSSHProcessSession: SSHProcessSession {
    private let onTermination: (SSHProcessSession) -> Void
    private(set) var writes: [Data] = []
    private(set) var terminationStatus: Int32 = 0
    private(set) var isRunning = true
    var processIdentifier: Int32 { 4242 }

    init(onTermination: @escaping (SSHProcessSession) -> Void) {
        self.onTermination = onTermination
    }

    var writtenStrings: [String] {
        writes.compactMap { String(data: $0, encoding: .utf8) }
    }

    func write(_ data: Data) {
        writes.append(data)
    }

    func terminate() {
        finish(status: 143)
    }

    func forceKill() {
        finish(status: 9)
    }

    func finish(status: Int32) {
        guard isRunning else { return }
        terminationStatus = status
        isRunning = false
        onTermination(self)
    }
}

private struct FakeInteractiveKeychain: GenericPasswordReading {
    var values: [String: String]

    func readGenericPassword(service: String, account: String) throws -> String {
        if let value = values["\(service)|\(account)"] {
            return value
        }
        throw KeychainServiceError.itemNotFound(service: service, account: account)
    }
}
