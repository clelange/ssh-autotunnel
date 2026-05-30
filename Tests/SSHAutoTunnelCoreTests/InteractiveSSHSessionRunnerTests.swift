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

    private func waitForSession(_ launcher: FakeInteractiveSSHProcessLauncher) throws -> FakeInteractiveSSHProcessSession {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let session = launcher.session {
                return session
            }
            usleep(1_000)
        }
        return try XCTUnwrap(launcher.session)
    }
}

private final class FakeInteractiveSSHProcessLauncher: SSHProcessLaunching {
    private let lock = NSLock()
    private(set) var command: SSHCommand?
    private var onOutput: ((Data) -> Void)?
    private(set) var session: FakeInteractiveSSHProcessSession?

    func launch(
        command: SSHCommand,
        onOutput: @escaping (Data) -> Void,
        onTermination: @escaping (SSHProcessSession) -> Void
    ) throws -> SSHProcessSession {
        lock.lock()
        defer { lock.unlock() }
        self.command = command
        self.onOutput = onOutput
        let session = FakeInteractiveSSHProcessSession(onTermination: onTermination)
        self.session = session
        return session
    }

    func output(_ text: String) {
        let data = Data(text.utf8)
        lock.lock()
        let onOutput = onOutput
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
