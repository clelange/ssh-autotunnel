import XCTest
@testable import SSHAutoTunnelCore

final class NetworkIdentityServiceTests: XCTestCase {
    func testParsesDefaultRouteOutput() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
        """

        XCTAssertEqual(NetworkIdentityParser.defaultInterface(routeOutput: output), "en0")
        XCTAssertEqual(NetworkIdentityParser.defaultGateway(routeOutput: output), "192.168.1.1")
    }

    func testParsesDNSOutput() {
        let output = """
        DNS configuration

        resolver #1
          search domain[0] : cern.ch
          nameserver[0] : 137.138.17.5
          nameserver[1] : 137.138.16.5

        resolver #2
          domain   : home.arpa
          nameserver[0] : 192.168.1.1
        """

        XCTAssertEqual(NetworkIdentityParser.dnsServers(scutilDNSOutput: output), [
            "137.138.17.5",
            "137.138.16.5",
            "192.168.1.1"
        ])
        XCTAssertEqual(NetworkIdentityParser.searchDomains(scutilDNSOutput: output), [
            "cern.ch",
            "home.arpa"
        ])
    }

    func testParsesIfconfigOutput() {
        let output = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            inet6 fe80::1%en0 prefixlen 64 secured scopeid 0x4
            inet 192.168.1.23 netmask 0xffffff00 broadcast 192.168.1.255
        utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
            inet 10.24.0.2 --> 10.24.0.2 netmask 0xffffffff
        """

        XCTAssertEqual(NetworkIdentityParser.ipv4Addresses(ifconfigOutput: output), [
            "192.168.1.23",
            "10.24.0.2"
        ])
        XCTAssertTrue(NetworkIdentityParser.hasVPNInterface(ifconfigOutput: output))
    }

    func testCurrentFingerprintUsesInjectedCommandOutputs() {
        var calls: [String] = []
        let outputs: [String: ShellResult] = [
            Self.key("/sbin/route", ["-n", "get", "default"]): ShellResult(
                exitCode: 0,
                stdout: """
                    gateway: 192.168.1.1
                  interface: en0
                """,
                stderr: ""
            ),
            Self.key("/usr/sbin/networksetup", ["-listnetworkserviceorder"]): ShellResult(
                exitCode: 0,
                stdout: """
                An asterisk (*) denotes that a network service is disabled.
                (1) Office Wi-Fi
                (Hardware Port: Wi-Fi, Device: en0)
                """,
                stderr: ""
            ),
            Self.key("/usr/sbin/scutil", ["--dns"]): ShellResult(
                exitCode: 0,
                stdout: """
                  search domain[0] : cern.ch
                  nameserver[0] : 137.138.17.5
                """,
                stderr: ""
            ),
            Self.key("/sbin/ifconfig", []): ShellResult(
                exitCode: 0,
                stdout: """
                en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                    inet 192.168.1.23 netmask 0xffffff00 broadcast 192.168.1.255
                utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
                    inet 10.24.0.2 --> 10.24.0.2 netmask 0xffffffff
                """,
                stderr: ""
            )
        ]
        let service = NetworkIdentityService(
            commandRunner: { executable, arguments in
                let commandKey = Self.key(executable, arguments)
                calls.append(commandKey)
                return outputs[commandKey] ?? ShellResult(exitCode: 1, stdout: "", stderr: "missing fake output")
            },
            wifiSSIDProvider: { "CERN" },
            wifiBSSIDProvider: { "AA:BB:CC:DD:EE:FF" }
        )

        let fingerprint = service.currentFingerprint()

        XCTAssertEqual(fingerprint.interfaceName, "en0")
        XCTAssertEqual(fingerprint.serviceName, "Office Wi-Fi")
        XCTAssertEqual(fingerprint.wifiSSID, "CERN")
        XCTAssertEqual(fingerprint.wifiBSSID, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(fingerprint.gateway, "192.168.1.1")
        XCTAssertEqual(fingerprint.dnsServers, ["137.138.17.5"])
        XCTAssertEqual(fingerprint.searchDomains, ["cern.ch"])
        XCTAssertEqual(fingerprint.ipv4Addresses, ["192.168.1.23", "10.24.0.2"])
        XCTAssertTrue(fingerprint.hasVPNInterface)
        XCTAssertEqual(
            Dictionary(grouping: calls, by: { $0 }).mapValues(\.count),
            outputs.mapValues { _ in 1 }
        )
    }

    func testCurrentFingerprintFallsBackToHardwarePortsWhenServiceOrderHasNoMatch() {
        let outputs: [String: ShellResult] = [
            Self.key("/sbin/route", ["-n", "get", "default"]): ShellResult(
                exitCode: 0,
                stdout: """
                    gateway: 192.168.1.1
                  interface: en0
                """,
                stderr: ""
            ),
            Self.key("/usr/sbin/networksetup", ["-listnetworkserviceorder"]): ShellResult(
                exitCode: 0,
                stdout: """
                An asterisk (*) denotes that a network service is disabled.
                (1) USB LAN
                (Hardware Port: USB LAN, Device: en7)
                """,
                stderr: ""
            ),
            Self.key("/usr/sbin/networksetup", ["-listallhardwareports"]): ShellResult(
                exitCode: 0,
                stdout: """
                Hardware Port: Wi-Fi
                Device: en0
                Ethernet Address: aa:bb:cc:dd:ee:ff
                """,
                stderr: ""
            )
        ]
        let service = NetworkIdentityService(
            commandRunner: { executable, arguments in
                outputs[Self.key(executable, arguments)] ?? ShellResult(exitCode: 1, stdout: "", stderr: "missing fake output")
            },
            wifiSSIDProvider: { nil },
            wifiBSSIDProvider: { nil }
        )

        XCTAssertEqual(service.currentFingerprint().serviceName, "Wi-Fi")
    }

    private static func key(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: "\u{1F}")
    }
}
