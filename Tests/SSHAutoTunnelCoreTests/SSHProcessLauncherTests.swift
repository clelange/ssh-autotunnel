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
}
