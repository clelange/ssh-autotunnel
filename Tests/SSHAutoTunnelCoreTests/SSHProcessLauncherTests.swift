import Darwin
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class SSHProcessLauncherTests: XCTestCase {
    func testPTYLauncherRunsInteractiveCommandWithInputAndOutput() throws {
        let launcher = PTYSSHProcessLauncher()
        let outputLock = NSLock()
        var output = Data()
        let sawResponse = expectation(description: "saw command response")
        let terminated = expectation(description: "process terminated")
        var terminationStatus: Int32?

        let session = try launcher.launch(
            command: SSHCommand(
                executable: "/bin/sh",
                arguments: ["-c", "read line; printf 'got:%s\\n' \"$line\""]
            ),
            terminalFileDescriptor: nil,
            onOutput: { data in
                outputLock.lock()
                output.append(data)
                let text = String(data: output, encoding: .utf8) ?? ""
                outputLock.unlock()
                if text.contains("got:hello") {
                    sawResponse.fulfill()
                }
            },
            onTermination: { session in
                terminationStatus = session.terminationStatus
                terminated.fulfill()
            }
        )

        session.write(Data("hello\n".utf8))

        wait(for: [sawResponse, terminated], timeout: 2)
        XCTAssertEqual(terminationStatus, 0)
    }

    func testPTYLauncherUsesProvidedInitialWindowSize() throws {
        let terminal = try SyntheticTerminal()
        try terminal.setWindowSize(rows: 37, columns: 119)
        let launcher = PTYSSHProcessLauncher()
        let outputLock = NSLock()
        var output = Data()
        let terminated = expectation(description: "process terminated")
        var terminationStatus: Int32?

        let session = try launcher.launch(
            command: SSHCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/stty size"]
            ),
            terminalFileDescriptor: terminal.slave.fileDescriptor,
            onOutput: { data in
                outputLock.lock()
                output.append(data)
                outputLock.unlock()
            },
            onTermination: { session in
                terminationStatus = session.terminationStatus
                terminated.fulfill()
            }
        )

        wait(for: [terminated], timeout: 2)
        withExtendedLifetime(session) {}

        outputLock.lock()
        let text = String(data: output, encoding: .utf8) ?? ""
        outputLock.unlock()
        XCTAssertEqual(terminationStatus, 0)
        XCTAssertTrue(text.contains("37 119"), "Expected child terminal size in output: \(text)")
    }

    func testPTYLauncherForwardsWindowChangesAndLatestSizeWins() throws {
        let terminal = try SyntheticTerminal()
        try terminal.setWindowSize(rows: 24, columns: 80)
        let launcher = PTYSSHProcessLauncher()
        let outputLock = NSLock()
        var output = Data()
        var sawReady = false
        var sawLargerSize = false
        var sawLatestSize = false
        let ready = expectation(description: "child installed resize handler")
        let larger = expectation(description: "child observed larger size")
        let latest = expectation(description: "child observed latest coalesced size")
        let terminated = expectation(description: "process terminated")

        let session = try launcher.launch(
            command: SSHCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    trap 'printf "SIZE:"; /bin/stty size' WINCH
                    printf 'READY\\n'
                    while :; do /bin/sleep 0.1; done
                    """
                ]
            ),
            terminalFileDescriptor: terminal.slave.fileDescriptor,
            onOutput: { data in
                outputLock.lock()
                output.append(data)
                let text = String(data: output, encoding: .utf8) ?? ""
                let shouldSignalReady = !sawReady && text.contains("READY")
                let shouldSignalLarger = !sawLargerSize && text.contains("SIZE:41 132")
                let shouldSignalLatest = !sawLatestSize && text.contains("SIZE:29 91")
                sawReady = sawReady || shouldSignalReady
                sawLargerSize = sawLargerSize || shouldSignalLarger
                sawLatestSize = sawLatestSize || shouldSignalLatest
                outputLock.unlock()

                if shouldSignalReady { ready.fulfill() }
                if shouldSignalLarger { larger.fulfill() }
                if shouldSignalLatest { latest.fulfill() }
            },
            onTermination: { _ in
                terminated.fulfill()
            }
        )

        wait(for: [ready], timeout: 2)

        try terminal.setWindowSize(rows: 41, columns: 132)
        XCTAssertEqual(kill(getpid(), SIGWINCH), 0)
        wait(for: [larger], timeout: 2)

        try terminal.setWindowSize(rows: 18, columns: 60)
        try terminal.setWindowSize(rows: 29, columns: 91)
        XCTAssertEqual(kill(getpid(), SIGWINCH), 0)
        wait(for: [latest], timeout: 2)

        session.terminate()
        wait(for: [terminated], timeout: 2)
    }

    func testWindowResizeMonitorStopsDeliveringAfterStop() throws {
        let terminal = try SyntheticTerminal()
        try terminal.setWindowSize(rows: 30, columns: 100)
        let callbackLock = NSLock()
        var sizes: [TerminalWindowSize] = []
        let initial = expectation(description: "initial size delivered")
        let resized = expectation(description: "resized size delivered")
        var sawInitial = false
        var sawResize = false
        let monitor = TerminalWindowResizeMonitor(fileDescriptor: terminal.slave.fileDescriptor) { size in
            callbackLock.lock()
            sizes.append(size)
            let shouldSignalInitial = !sawInitial && size == TerminalWindowSize(rows: 30, columns: 100)
            let shouldSignalResize = !sawResize && size == TerminalWindowSize(rows: 45, columns: 140)
            sawInitial = sawInitial || shouldSignalInitial
            sawResize = sawResize || shouldSignalResize
            callbackLock.unlock()

            if shouldSignalInitial { initial.fulfill() }
            if shouldSignalResize { resized.fulfill() }
        }

        XCTAssertTrue(monitor.start())
        wait(for: [initial], timeout: 1)

        try terminal.setWindowSize(rows: 45, columns: 140)
        XCTAssertEqual(kill(getpid(), SIGWINCH), 0)
        wait(for: [resized], timeout: 2)

        monitor.stop()
        callbackLock.lock()
        let countAfterStop = sizes.count
        callbackLock.unlock()

        try terminal.setWindowSize(rows: 50, columns: 160)
        XCTAssertEqual(kill(getpid(), SIGWINCH), 0)
        usleep(100_000)

        callbackLock.lock()
        let finalCount = sizes.count
        callbackLock.unlock()
        XCTAssertEqual(finalCount, countAfterStop)
    }

    func testWindowResizeMonitorDeclinesNonTerminalDescriptor() {
        let pipe = Pipe()
        let monitor = TerminalWindowResizeMonitor(fileDescriptor: pipe.fileHandleForReading.fileDescriptor) { _ in
            XCTFail("Non-terminal descriptors must not produce window sizes")
        }

        XCTAssertFalse(monitor.start())
    }
}

private final class SyntheticTerminal {
    let master: FileHandle
    let slave: FileHandle

    init() throws {
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0 else {
            throw Self.posixError("Could not create synthetic terminal")
        }
        master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
        slave = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: true)
    }

    func setWindowSize(rows: UInt16, columns: UInt16) throws {
        var size = TerminalWindowSize(rows: rows, columns: columns).systemValue
        guard ioctl(slave.fileDescriptor, TIOCSWINSZ, &size) == 0 else {
            throw Self.posixError("Could not resize synthetic terminal")
        }
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
