import XCTest
@testable import SSHAutoTunnelCore

final class CLIArgumentsTests: XCTestCase {
    func testParsesJSONFlagBeforeCommand() {
        let invocation = CLIArguments.parse(["--json", "status"])
        XCTAssertEqual(invocation, CLIInvocation(command: "status", outputJSON: true))
    }

    func testParsesJSONFlagAfterProfileName() {
        let invocation = CLIArguments.parse(["connect", "CERN", "lxplus", "--json"])
        XCTAssertEqual(invocation, CLIInvocation(command: "connect", profileName: "CERN lxplus", outputJSON: true))
    }

    func testReturnsNilForEmptyArguments() {
        XCTAssertNil(CLIArguments.parse([]))
    }

    func testParsesAutomationCommand() {
        let invocation = CLIArguments.parse(["check-ssh-auto2fa", "--json"])
        XCTAssertEqual(invocation, CLIInvocation(command: "check-ssh-auto2fa", outputJSON: true))
    }
}
