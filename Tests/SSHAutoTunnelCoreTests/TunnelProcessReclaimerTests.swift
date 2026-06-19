import Darwin
import Foundation
import XCTest
@testable import SSHAutoTunnelCore

final class TunnelProcessReclaimerTests: XCTestCase {
    func testReclaimsRegistryBackedStaleProcess() {
        let profile = testProfile()
        let registry = MemoryTunnelProcessRegistry(records: [
            record(for: profile, pid: 42, port: 1099)
        ])
        let controller = FakeSSHProcessController(
            metadata: [
                42: SSHProcessMetadata(
                    pid: 42,
                    processGroupID: 42,
                    command: "/usr/bin/ssh -N -D 127.0.0.1:1099 -p 22 alice@ssh.example.org"
                )
            ],
            runningPIDs: [42],
            terminateExitsPIDs: [42]
        )
        let reclaimer = TunnelProcessReclaimer(
            registry: registry,
            listenerInspector: FakeSocksListenerInspector(),
            processController: controller,
            terminateGrace: 0,
            killGrace: 0
        )

        let result = reclaimer.reclaimStaleProcesses(for: profile, configuredPort: 1099, activePIDs: [])

        XCTAssertEqual(
            result.reclaimed,
            [TunnelProcessReclaimedProcess(pid: 42, port: 1099, reason: "registered stale tunnel process")]
        )
        XCTAssertTrue(result.blockers.isEmpty)
        XCTAssertEqual(controller.signals, [.init(signal: SIGTERM, target: .processGroup(42))])
        XCTAssertTrue(registry.records().isEmpty)
    }

    func testReclaimsMatchingListenerProcess() {
        let profile = testProfile()
        let controller = FakeSSHProcessController(
            metadata: [
                43: SSHProcessMetadata(
                    pid: 43,
                    processGroupID: 43,
                    command: "/usr/bin/ssh -N -D 127.0.0.1:1099 -p 22 -o ExitOnForwardFailure=yes alice@ssh.example.org"
                )
            ],
            runningPIDs: [43],
            terminateExitsPIDs: [43]
        )
        let reclaimer = TunnelProcessReclaimer(
            registry: MemoryTunnelProcessRegistry(),
            listenerInspector: FakeSocksListenerInspector(listeners: [SocksListener(pid: 43, processName: "ssh", port: 1099, endpoint: "127.0.0.1:1099")]),
            processController: controller,
            terminateGrace: 0,
            killGrace: 0
        )

        let result = reclaimer.reclaimStaleProcesses(for: profile, configuredPort: 1099, activePIDs: [])

        XCTAssertEqual(
            result.reclaimed,
            [TunnelProcessReclaimedProcess(pid: 43, port: 1099, reason: "matching stale SSH tunnel listener")]
        )
        XCTAssertTrue(result.blockers.isEmpty)
        XCTAssertEqual(controller.signals, [.init(signal: SIGTERM, target: .processGroup(43))])
    }

    func testUnknownListenerBlocksReclaim() {
        let profile = testProfile()
        let controller = FakeSSHProcessController(
            metadata: [
                44: SSHProcessMetadata(pid: 44, processGroupID: 44, command: "/usr/bin/python3 -m http.server 1099")
            ],
            runningPIDs: [44]
        )
        let reclaimer = TunnelProcessReclaimer(
            registry: MemoryTunnelProcessRegistry(),
            listenerInspector: FakeSocksListenerInspector(listeners: [SocksListener(pid: 44, processName: "python3", port: 1099, endpoint: "127.0.0.1:1099")]),
            processController: controller,
            terminateGrace: 0,
            killGrace: 0
        )

        let result = reclaimer.reclaimStaleProcesses(for: profile, configuredPort: 1099, activePIDs: [])

        XCTAssertTrue(result.reclaimed.isEmpty)
        XCTAssertEqual(
            result.blockers,
            [
                TunnelProcessReclaimBlocker(
                    pid: 44,
                    port: 1099,
                    reason: "listener is not a verified stale SSH AutoTunnel process"
                )
            ]
        )
        XCTAssertTrue(controller.signals.isEmpty)
    }

    func testUsesSIGKILLFallbackWhenSIGTERMDoesNotExit() {
        let profile = testProfile()
        let controller = FakeSSHProcessController(
            metadata: [
                45: SSHProcessMetadata(
                    pid: 45,
                    processGroupID: 45,
                    command: "/usr/bin/ssh -N -D 127.0.0.1:1099 -p 22 alice@ssh.example.org"
                )
            ],
            runningPIDs: [45],
            killExitsPIDs: [45]
        )
        let reclaimer = TunnelProcessReclaimer(
            registry: MemoryTunnelProcessRegistry(),
            listenerInspector: FakeSocksListenerInspector(listeners: [SocksListener(pid: 45, processName: "ssh", port: 1099, endpoint: "127.0.0.1:1099")]),
            processController: controller,
            terminateGrace: 0,
            killGrace: 0
        )

        let result = reclaimer.reclaimStaleProcesses(for: profile, configuredPort: 1099, activePIDs: [])

        XCTAssertEqual(result.reclaimed.count, 1)
        XCTAssertEqual(
            controller.signals,
            [
                .init(signal: SIGTERM, target: .processGroup(45)),
                .init(signal: SIGKILL, target: .processGroup(45))
            ]
        )
    }

    private func testProfile() -> TunnelProfile {
        TunnelProfile(
            name: "Test",
            host: "ssh.example.org",
            user: "alice",
            localSocksPort: 1099
        )
    }

    private func record(for profile: TunnelProfile, pid: Int32, port: Int) -> TunnelProcessRecord {
        TunnelProcessRecord(
            profileID: profile.id,
            profileName: profile.name,
            configuredSocksPort: profile.localSocksPort,
            effectiveSocksPort: port,
            pid: pid,
            command: SSHCommand(arguments: ["-N", "-D", "127.0.0.1:\(port)", "-p", "\(profile.sshPort)", profile.sshDestination]),
            startedAt: Date(timeIntervalSince1970: TimeInterval(pid))
        )
    }
}

private final class MemoryTunnelProcessRegistry: TunnelProcessRecording {
    private var storedRecords: [TunnelProcessRecord]

    init(records: [TunnelProcessRecord] = []) {
        storedRecords = records
    }

    func records() -> [TunnelProcessRecord] {
        storedRecords
    }

    func records(for profileID: UUID) -> [TunnelProcessRecord] {
        storedRecords.filter { $0.profileID == profileID }
    }

    func upsert(_ record: TunnelProcessRecord) {
        storedRecords.removeAll { $0.profileID == record.profileID && $0.pid == record.pid }
        storedRecords.append(record)
    }

    func remove(profileID: UUID, pid: Int32) {
        storedRecords.removeAll { $0.profileID == profileID && $0.pid == pid }
    }

    func pruneInactive() {}
}

private struct FakeSocksListenerInspector: SocksListenerInspecting {
    var listeners: [SocksListener] = []

    func listeners(onLoopbackPort port: Int) -> [SocksListener] {
        listeners.filter { $0.port == port }
    }
}

private final class FakeSSHProcessController: SSHProcessControlling {
    struct Signal: Equatable {
        enum Target: Equatable {
            case processGroup(Int32)
            case pid(Int32)
        }

        var signal: Int32
        var target: Target
    }

    private let metadataByPID: [Int32: SSHProcessMetadata]
    private var runningPIDs: Set<Int32>
    private let terminateExitsPIDs: Set<Int32>
    private let killExitsPIDs: Set<Int32>
    private(set) var signals: [Signal] = []

    init(
        metadata: [Int32: SSHProcessMetadata],
        runningPIDs: Set<Int32>,
        terminateExitsPIDs: Set<Int32> = [],
        killExitsPIDs: Set<Int32> = []
    ) {
        metadataByPID = metadata
        self.runningPIDs = runningPIDs
        self.terminateExitsPIDs = terminateExitsPIDs
        self.killExitsPIDs = killExitsPIDs
    }

    func metadata(for pid: Int32) -> SSHProcessMetadata? {
        metadataByPID[pid]
    }

    func processIsRunning(_ pid: Int32) -> Bool {
        runningPIDs.contains(pid)
    }

    func sendSignal(_ signal: Int32, toProcessGroup groupID: Int32) -> Bool {
        signals.append(Signal(signal: signal, target: .processGroup(groupID)))
        apply(signal: signal, to: groupID)
        return true
    }

    func sendSignal(_ signal: Int32, toPID pid: Int32) -> Bool {
        signals.append(Signal(signal: signal, target: .pid(pid)))
        apply(signal: signal, to: pid)
        return true
    }

    private func apply(signal: Int32, to pid: Int32) {
        if signal == SIGTERM, terminateExitsPIDs.contains(pid) {
            runningPIDs.remove(pid)
        }
        if signal == SIGKILL, killExitsPIDs.contains(pid) {
            runningPIDs.remove(pid)
        }
    }
}
