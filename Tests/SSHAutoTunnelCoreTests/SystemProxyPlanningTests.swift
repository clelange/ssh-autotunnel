import XCTest
@testable import SSHAutoTunnelCore

final class SystemProxyPlanningTests: XCTestCase {
    func testParsesEnabledAutoProxySnapshot() {
        let snapshot = NetworkSetupParser.autoProxySnapshot(
            serviceName: "Wi-Fi",
            output: """
            URL: http://127.0.0.1:18483/proxy.pac
            Enabled: Yes
            """
        )

        XCTAssertEqual(snapshot.serviceName, "Wi-Fi")
        XCTAssertTrue(snapshot.autoProxyEnabled)
        XCTAssertEqual(snapshot.autoProxyURL, "http://127.0.0.1:18483/proxy.pac")
    }

    func testParsesDisabledAutoProxySnapshot() {
        let snapshot = NetworkSetupParser.autoProxySnapshot(
            serviceName: "USB LAN",
            output: """
            URL:
            Enabled: No
            """
        )

        XCTAssertEqual(snapshot.serviceName, "USB LAN")
        XCTAssertFalse(snapshot.autoProxyEnabled)
        XCTAssertNil(snapshot.autoProxyURL)
    }

    func testParsesNumericEnabledAutoProxySnapshot() {
        let snapshot = NetworkSetupParser.autoProxySnapshot(
            serviceName: "Ethernet",
            output: """
            Enabled: 1
            URL: file:///tmp/proxy.pac
            """
        )

        XCTAssertTrue(snapshot.autoProxyEnabled)
        XCTAssertEqual(snapshot.autoProxyURL, "file:///tmp/proxy.pac")
    }

    func testFindsServiceNameForDevice() {
        let output = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 00:11:22:33:44:55

        Hardware Port: USB 10/100/1000 LAN
        Device: en7
        Ethernet Address: aa:bb:cc:dd:ee:ff
        """

        XCTAssertEqual(
            NetworkSetupParser.serviceName(forDevice: "en7", hardwarePortsOutput: output),
            "USB 10/100/1000 LAN"
        )
    }

    func testReturnsNilForUnknownDevice() {
        let output = """
        Hardware Port: Wi-Fi
        Device: en0
        """

        XCTAssertNil(NetworkSetupParser.serviceName(forDevice: "en9", hardwarePortsOutput: output))
    }

    func testPlansApplyPACCommands() {
        let commands = SystemProxyPlanner.applyPACCommands(
            serviceName: "Wi-Fi",
            pacURL: "http://127.0.0.1:18483/proxy.pac"
        )

        XCTAssertEqual(commands, [
            NetworkSetupCommand(arguments: ["-setautoproxyurl", "Wi-Fi", "http://127.0.0.1:18483/proxy.pac"]),
            NetworkSetupCommand(arguments: ["-setautoproxystate", "Wi-Fi", "on"])
        ])
    }

    func testPlansRestoreCommandsForEnabledSnapshotWithURL() {
        let snapshot = ProxySnapshot(
            serviceName: "Wi-Fi",
            autoProxyEnabled: true,
            autoProxyURL: "http://existing.example/proxy.pac"
        )

        XCTAssertEqual(SystemProxyPlanner.restoreCommands(snapshot: snapshot), [
            NetworkSetupCommand(arguments: ["-setautoproxyurl", "Wi-Fi", "http://existing.example/proxy.pac"]),
            NetworkSetupCommand(arguments: ["-setautoproxystate", "Wi-Fi", "on"])
        ])
    }

    func testPlansRestoreCommandsForDisabledSnapshotWithoutURL() {
        let snapshot = ProxySnapshot(serviceName: "Wi-Fi", autoProxyEnabled: false, autoProxyURL: nil)

        XCTAssertEqual(SystemProxyPlanner.restoreCommands(snapshot: snapshot), [
            NetworkSetupCommand(arguments: ["-setautoproxystate", "Wi-Fi", "off"])
        ])
    }
}
