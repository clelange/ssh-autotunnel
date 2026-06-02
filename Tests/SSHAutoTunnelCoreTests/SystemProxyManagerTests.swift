import XCTest
@testable import SSHAutoTunnelCore

final class SystemProxyManagerTests: XCTestCase {
    func testApplyPACCapturesCurrentSnapshotAndRunsApplyCommands() throws {
        let store = FakeProxySnapshotStore()
        var commands: [NetworkSetupCommand] = []
        let manager = SystemProxyManager(
            snapshotStore: store,
            currentServiceName: { "Wi-Fi" },
            commandRunner: { command in
                commands.append(command)
                if command.arguments.first == "-getautoproxyurl" {
                    return ShellResult(
                        exitCode: 0,
                        stdout: """
                        URL: http://existing.example/proxy.pac
                        Enabled: Yes
                        """,
                        stderr: ""
                    )
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let service = try manager.applyPAC(url: "http://127.0.0.1:18483/proxy.pac")

        XCTAssertEqual(service, "Wi-Fi")
        XCTAssertEqual(store.savedArchives, [[
            ProxySnapshot(
                serviceName: "Wi-Fi",
                autoProxyEnabled: true,
                autoProxyURL: "http://existing.example/proxy.pac"
            )
        ]])
        XCTAssertEqual(commands, [
            NetworkSetupCommand(arguments: ["-getautoproxyurl", "Wi-Fi"]),
            NetworkSetupCommand(arguments: ["-setautoproxyurl", "Wi-Fi", "http://127.0.0.1:18483/proxy.pac"]),
            NetworkSetupCommand(arguments: ["-setautoproxystate", "Wi-Fi", "on"])
        ])
    }

    func testApplyPACRequiresActiveNetworkService() {
        let store = FakeProxySnapshotStore()
        let manager = SystemProxyManager(
            snapshotStore: store,
            currentServiceName: { nil },
            commandRunner: { _ in
                XCTFail("No commands should run without an active service")
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        XCTAssertThrowsError(try manager.applyPAC(url: "http://127.0.0.1:18483/proxy.pac")) { error in
            XCTAssertEqual(error as? SystemProxyManagerError, .missingActiveNetworkService)
        }
        XCTAssertTrue(store.savedArchives.isEmpty)
    }

    func testPACStatusReportsActiveServiceUsingExpectedPAC() {
        let manager = SystemProxyManager(
            snapshotStore: nil,
            currentServiceName: { "Wi-Fi" },
            commandRunner: { command in
                XCTAssertEqual(command, NetworkSetupCommand(arguments: ["-getautoproxyurl", "Wi-Fi"]))
                return ShellResult(
                    exitCode: 0,
                    stdout: """
                    URL: http://127.0.0.1:18483/proxy.pac?v=123
                    Enabled: Yes
                    """,
                    stderr: ""
                )
            }
        )

        let status = manager.pacStatus(expectedURL: "http://127.0.0.1:18483/proxy.pac?v=123")

        XCTAssertEqual(status.state, .active)
        XCTAssertEqual(status.serviceName, "Wi-Fi")
        XCTAssertEqual(status.observedPACURL, "http://127.0.0.1:18483/proxy.pac?v=123")
        XCTAssertEqual(status.autoProxyEnabled, true)
        XCTAssertNil(status.errorMessage)
    }

    func testPACStatusReportsStaleAutoTunnelPACWhenOnlyVersionDiffers() {
        let manager = SystemProxyManager(
            snapshotStore: nil,
            currentServiceName: { "Wi-Fi" },
            commandRunner: { _ in
                ShellResult(
                    exitCode: 0,
                    stdout: """
                    URL: http://127.0.0.1:18483/proxy.pac?v=old
                    Enabled: Yes
                    """,
                    stderr: ""
                )
            }
        )

        let status = manager.pacStatus(expectedURL: "http://127.0.0.1:18483/proxy.pac?v=new")

        XCTAssertEqual(status.state, .staleAutoTunnelPAC)
        XCTAssertEqual(status.serviceName, "Wi-Fi")
        XCTAssertEqual(status.observedPACURL, "http://127.0.0.1:18483/proxy.pac?v=old")
    }

    func testPACStatusReportsMissingPACOnActiveService() {
        let manager = SystemProxyManager(
            snapshotStore: nil,
            currentServiceName: { "USB 10/100/1000 LAN" },
            commandRunner: { _ in
                ShellResult(
                    exitCode: 0,
                    stdout: """
                    URL:
                    Enabled: No
                    """,
                    stderr: ""
                )
            }
        )

        let status = manager.pacStatus(expectedURL: "http://127.0.0.1:18483/proxy.pac?v=123")

        XCTAssertEqual(status.state, .notConfigured)
        XCTAssertEqual(status.serviceName, "USB 10/100/1000 LAN")
        XCTAssertEqual(status.autoProxyEnabled, false)
        XCTAssertNil(status.observedPACURL)
    }

    func testPACStatusReportsOtherPACOnActiveService() {
        let manager = SystemProxyManager(
            snapshotStore: nil,
            currentServiceName: { "Wi-Fi" },
            commandRunner: { _ in
                ShellResult(
                    exitCode: 0,
                    stdout: """
                    URL: https://proxy.example/proxy.pac
                    Enabled: Yes
                    """,
                    stderr: ""
                )
            }
        )

        let status = manager.pacStatus(expectedURL: "http://127.0.0.1:18483/proxy.pac?v=123")

        XCTAssertEqual(status.state, .otherPAC)
        XCTAssertEqual(status.observedPACURL, "https://proxy.example/proxy.pac")
    }

    func testPACStatusReportsUnknownWithoutActiveService() {
        let manager = SystemProxyManager(
            snapshotStore: nil,
            currentServiceName: { nil },
            commandRunner: { _ in
                XCTFail("No commands should run without an active service")
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let status = manager.pacStatus(expectedURL: "http://127.0.0.1:18483/proxy.pac?v=123")

        XCTAssertEqual(status.state, .unknown)
        XCTAssertNil(status.serviceName)
        XCTAssertEqual(status.errorMessage, "Could not determine active network service")
    }

    func testPACStatusReportsNetworkSetupFailure() {
        let manager = SystemProxyManager(
            snapshotStore: nil,
            currentServiceName: { "Wi-Fi" },
            commandRunner: { _ in
                ShellResult(exitCode: 1, stdout: "", stderr: "Wi-Fi is not a network service.")
            }
        )

        let status = manager.pacStatus(expectedURL: "http://127.0.0.1:18483/proxy.pac?v=123")

        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.serviceName, "Wi-Fi")
        XCTAssertEqual(status.errorMessage, "Wi-Fi is not a network service.")
    }

    func testApplyPACReusesSnapshotForSameService() throws {
        let store = FakeProxySnapshotStore()
        var commands: [NetworkSetupCommand] = []
        let manager = SystemProxyManager(
            snapshotStore: store,
            currentServiceName: { "Wi-Fi" },
            commandRunner: { command in
                commands.append(command)
                return ShellResult(
                    exitCode: 0,
                    stdout: """
                    URL:
                    Enabled: No
                    """,
                    stderr: ""
                )
            }
        )

        _ = try manager.applyPAC(url: "http://127.0.0.1:18483/proxy.pac")
        _ = try manager.applyPAC(url: "http://127.0.0.1:18483/proxy.pac")

        XCTAssertEqual(store.currentSnapshots, [
            ProxySnapshot(serviceName: "Wi-Fi", autoProxyEnabled: false, autoProxyURL: nil)
        ])
        XCTAssertEqual(store.savedArchives.count, 1)
        XCTAssertEqual(commands.filter { $0.arguments.first == "-getautoproxyurl" }.count, 1)
        XCTAssertEqual(commands.filter { $0.arguments.first == "-setautoproxyurl" }.count, 2)
    }

    func testApplyPACPreservesSnapshotsForMultipleServicesAndRestoresAll() throws {
        let store = FakeProxySnapshotStore()
        var activeService = "Wi-Fi"
        var commands: [NetworkSetupCommand] = []
        let manager = SystemProxyManager(
            snapshotStore: store,
            currentServiceName: { activeService },
            commandRunner: { command in
                commands.append(command)
                if command.arguments.first == "-getautoproxyurl" {
                    let serviceName = command.arguments[1]
                    switch serviceName {
                    case "Wi-Fi":
                        return ShellResult(
                            exitCode: 0,
                            stdout: """
                            URL: http://wifi.example/proxy.pac
                            Enabled: Yes
                            """,
                            stderr: ""
                        )
                    case "USB 10/100/1000 LAN":
                        return ShellResult(
                            exitCode: 0,
                            stdout: """
                            URL:
                            Enabled: No
                            """,
                            stderr: ""
                        )
                    default:
                        XCTFail("Unexpected service \(serviceName)")
                    }
                }
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        _ = try manager.applyPAC(url: "http://127.0.0.1:18483/proxy.pac")
        activeService = "USB 10/100/1000 LAN"
        _ = try manager.applyPAC(url: "http://127.0.0.1:18483/proxy.pac")

        XCTAssertEqual(store.currentSnapshots, [
            ProxySnapshot(serviceName: "USB 10/100/1000 LAN", autoProxyEnabled: false, autoProxyURL: nil),
            ProxySnapshot(serviceName: "Wi-Fi", autoProxyEnabled: true, autoProxyURL: "http://wifi.example/proxy.pac")
        ])

        commands.removeAll()
        try manager.restoreIfNeeded()

        XCTAssertEqual(commands, [
            NetworkSetupCommand(arguments: ["-setautoproxystate", "USB 10/100/1000 LAN", "off"]),
            NetworkSetupCommand(arguments: ["-setautoproxyurl", "Wi-Fi", "http://wifi.example/proxy.pac"]),
            NetworkSetupCommand(arguments: ["-setautoproxystate", "Wi-Fi", "on"])
        ])
        XCTAssertTrue(store.didClear)
    }

    func testRestoreLoadsPersistedSnapshotRunsRestoreCommandsAndClearsStore() throws {
        let snapshot = ProxySnapshot(
            serviceName: "Wi-Fi",
            autoProxyEnabled: true,
            autoProxyURL: "http://existing.example/proxy.pac"
        )
        let store = FakeProxySnapshotStore(snapshots: [snapshot])
        var commands: [NetworkSetupCommand] = []
        let manager = SystemProxyManager(
            snapshotStore: store,
            currentServiceName: { nil },
            commandRunner: { command in
                commands.append(command)
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        try manager.restoreIfNeeded()

        XCTAssertEqual(commands, [
            NetworkSetupCommand(arguments: ["-setautoproxyurl", "Wi-Fi", "http://existing.example/proxy.pac"]),
            NetworkSetupCommand(arguments: ["-setautoproxystate", "Wi-Fi", "on"])
        ])
        XCTAssertTrue(store.didClear)
    }

    func testRestorePropagatesPersistedSnapshotLoadError() {
        let store = FakeProxySnapshotStore(loadError: .loadFailed)
        var commands: [NetworkSetupCommand] = []
        let manager = SystemProxyManager(
            snapshotStore: store,
            currentServiceName: { nil },
            commandRunner: { command in
                commands.append(command)
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        XCTAssertThrowsError(try manager.restoreIfNeeded()) { error in
            XCTAssertEqual(error as? FakeProxySnapshotStore.StoreError, .loadFailed)
        }
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(store.didClear)
    }
}

private final class FakeProxySnapshotStore: ProxySnapshotStoring {
    enum StoreError: Error, Equatable {
        case loadFailed
    }

    private var snapshots: [ProxySnapshot]
    private var loadError: StoreError?
    private(set) var savedArchives: [[ProxySnapshot]] = []
    private(set) var didClear = false

    var currentSnapshots: [ProxySnapshot] {
        snapshots.sorted { $0.serviceName < $1.serviceName }
    }

    init(snapshots: [ProxySnapshot] = [], loadError: StoreError? = nil) {
        self.snapshots = snapshots
        self.loadError = loadError
    }

    func saveAll(_ snapshots: [ProxySnapshot]) throws {
        let sorted = snapshots.sorted { $0.serviceName < $1.serviceName }
        savedArchives.append(sorted)
        self.snapshots = sorted
    }

    func loadAll() throws -> [ProxySnapshot] {
        if let loadError {
            throw loadError
        }
        return snapshots
    }

    func clear() throws {
        didClear = true
        snapshots = []
    }
}
