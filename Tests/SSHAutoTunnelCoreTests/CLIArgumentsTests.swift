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

    func testParsesInteractiveSSHCommand() {
        let invocation = CLIArguments.parse(["interactive-ssh", "CERN", "LxPlus"])
        XCTAssertEqual(invocation, CLIInvocation(command: "interactive-ssh", profileName: "CERN LxPlus"))
    }

    func testParsesDirectInteractiveSSHCommand() {
        let invocation = CLIArguments.parse(["interactive-ssh-direct", "PSI", "General"])
        XCTAssertEqual(invocation, CLIInvocation(command: "interactive-ssh-direct", profileName: "PSI General"))
    }

    func testParsesHopCommands() {
        XCTAssertEqual(
            CLIArguments.parse(["connect-hop", "PSI", "General"]),
            CLIInvocation(command: "connect-hop", profileName: "PSI General")
        )
        XCTAssertEqual(
            CLIArguments.parse(["disconnect-hop", "PSI", "General"]),
            CLIInvocation(command: "disconnect-hop", profileName: "PSI General")
        )
        XCTAssertEqual(
            CLIArguments.parse(["reconnect-hop", "PSI", "General"]),
            CLIInvocation(command: "reconnect-hop", profileName: "PSI General")
        )
    }

    func testParsesSplitInteractiveSSHCommands() {
        XCTAssertEqual(
            CLIArguments.parse(["interactive-ssh-jump", "PSI", "General"]),
            CLIInvocation(command: "interactive-ssh-jump", profileName: "PSI General")
        )
        XCTAssertEqual(
            CLIArguments.parse(["interactive-ssh-final", "PSI", "General"]),
            CLIInvocation(command: "interactive-ssh-final", profileName: "PSI General")
        )
        XCTAssertEqual(
            CLIArguments.parse(["interactive-ssh-final-ready", "PSI", "General"]),
            CLIInvocation(command: "interactive-ssh-final-ready", profileName: "PSI General")
        )
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

    func testParsesReadOnlySSHConfigAuditCommand() {
        let invocation = CLIArguments.parse(["check-ssh-config", "--json"])
        XCTAssertEqual(invocation, CLIInvocation(command: "check-ssh-config", outputJSON: true))
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

    func testParsesDirectCurrentNetworkAlias() {
        XCTAssertEqual(
            CLIArguments.parse(["use-direct-current-network", "PSI", "General"]),
            CLIInvocation(command: "use-direct-current-network", profileName: "PSI General")
        )
    }
}
