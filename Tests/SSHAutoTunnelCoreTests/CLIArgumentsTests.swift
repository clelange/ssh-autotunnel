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

    func testParsesDiagnosticsCommand() {
        let invocation = CLIArguments.parse(["diagnostics", "--json"])
        XCTAssertEqual(invocation, CLIInvocation(command: "diagnostics", outputJSON: true))
    }

    func testParsesConfigurationPortabilityCommands() {
        XCTAssertEqual(
            CLIArguments.parse(["export-config", "~/ssh-autotunnel-export.json"]),
            CLIInvocation(command: "export-config", profileName: "~/ssh-autotunnel-export.json")
        )
        XCTAssertEqual(
            CLIArguments.parse(["import-config", "-"]),
            CLIInvocation(command: "import-config", profileName: "-")
        )
        XCTAssertEqual(
            CLIArguments.parse(["validate-config", "~/ssh-autotunnel-export.json"]),
            CLIInvocation(command: "validate-config", profileName: "~/ssh-autotunnel-export.json")
        )
        XCTAssertEqual(
            CLIArguments.parse(["support-bundle", "--json"]),
            CLIInvocation(command: "support-bundle", outputJSON: true)
        )
    }

    func testParsesSSHConfigImportCommand() {
        let invocation = CLIArguments.parse(["import-ssh-config"])
        XCTAssertEqual(invocation, CLIInvocation(command: "import-ssh-config"))
    }

    func testParsesProfileManagementCommands() {
        XCTAssertEqual(
            CLIArguments.parse(["create-profile", "~/profile.json"]),
            CLIInvocation(command: "create-profile", profileName: "~/profile.json")
        )
        XCTAssertEqual(
            CLIArguments.parse(["delete-profile", "CERN", "lxplus"]),
            CLIInvocation(command: "delete-profile", profileName: "CERN lxplus")
        )
        XCTAssertEqual(
            CLIArguments.parse(["delete-profile", "--delete-keychain", "CERN", "lxplus"]),
            CLIInvocation(command: "delete-profile", profileName: "CERN lxplus", deleteKeychainItems: true)
        )
    }

    func testParsesProfileTemplateCommand() {
        let invocation = CLIArguments.parse(["profile-template"])
        XCTAssertEqual(invocation, CLIInvocation(command: "profile-template"))
    }

    func testParsesPACRuleManagementCommands() {
        XCTAssertEqual(
            CLIArguments.parse(["pac-rule-template"]),
            CLIInvocation(command: "pac-rule-template")
        )
        XCTAssertEqual(
            CLIArguments.parse(["create-pac-rule", "~/pac-rule.json"]),
            CLIInvocation(command: "create-pac-rule", profileName: "~/pac-rule.json")
        )
        XCTAssertEqual(
            CLIArguments.parse(["delete-pac-rule", "CERN"]),
            CLIInvocation(command: "delete-pac-rule", profileName: "CERN")
        )
    }

    func testParsesNetworkRuleManagementCommands() {
        XCTAssertEqual(
            CLIArguments.parse(["network-rule-template"]),
            CLIInvocation(command: "network-rule-template")
        )
        XCTAssertEqual(
            CLIArguments.parse(["create-network-rule", "~/network-rule.json"]),
            CLIInvocation(command: "create-network-rule", profileName: "~/network-rule.json")
        )
        XCTAssertEqual(
            CLIArguments.parse(["update-network-rule", "~/network-rule.json"]),
            CLIInvocation(command: "update-network-rule", profileName: "~/network-rule.json")
        )
        XCTAssertEqual(
            CLIArguments.parse(["delete-network-rule", "CERN trusted network"]),
            CLIInvocation(command: "delete-network-rule", profileName: "CERN trusted network")
        )
        XCTAssertEqual(
            CLIArguments.parse(["trust-current-network", "CERN lxplus"]),
            CLIInvocation(command: "trust-current-network", profileName: "CERN lxplus")
        )
    }
}
