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
        XCTAssertEqual(store.savedSnapshots, [
            ProxySnapshot(
                serviceName: "Wi-Fi",
                autoProxyEnabled: true,
                autoProxyURL: "http://existing.example/proxy.pac"
            )
        ])
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
        XCTAssertTrue(store.savedSnapshots.isEmpty)
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

        XCTAssertEqual(store.savedSnapshots, [
            ProxySnapshot(serviceName: "Wi-Fi", autoProxyEnabled: false, autoProxyURL: nil)
        ])
        XCTAssertEqual(commands.filter { $0.arguments.first == "-getautoproxyurl" }.count, 1)
        XCTAssertEqual(commands.filter { $0.arguments.first == "-setautoproxyurl" }.count, 2)
    }

    func testRestoreLoadsPersistedSnapshotRunsRestoreCommandsAndClearsStore() throws {
        let snapshot = ProxySnapshot(
            serviceName: "Wi-Fi",
            autoProxyEnabled: true,
            autoProxyURL: "http://existing.example/proxy.pac"
        )
        let store = FakeProxySnapshotStore(snapshot: snapshot)
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

    private var snapshot: ProxySnapshot?
    private var loadError: StoreError?
    private(set) var savedSnapshots: [ProxySnapshot] = []
    private(set) var didClear = false

    init(snapshot: ProxySnapshot? = nil, loadError: StoreError? = nil) {
        self.snapshot = snapshot
        self.loadError = loadError
    }

    func save(_ snapshot: ProxySnapshot) throws {
        savedSnapshots.append(snapshot)
        self.snapshot = snapshot
    }

    func load() throws -> ProxySnapshot? {
        if let loadError {
            throw loadError
        }
        return snapshot
    }

    func clear() throws {
        didClear = true
        snapshot = nil
    }
}
