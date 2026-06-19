import Darwin
import Foundation

struct TunnelProcessReclaimedProcess: Equatable, Sendable {
    var pid: Int32
    var port: Int
    var reason: String
}

struct TunnelProcessReclaimBlocker: Equatable, Sendable {
    var pid: Int32?
    var port: Int
    var reason: String
}

struct TunnelProcessReclaimResult: Equatable, Sendable {
    var reclaimed: [TunnelProcessReclaimedProcess] = []
    var blockers: [TunnelProcessReclaimBlocker] = []
}

struct TunnelProcessReclaimError: LocalizedError, Equatable, Sendable {
    var port: Int
    var reason: String

    var errorDescription: String? {
        "Local SOCKS port \(port) is already in use: \(reason)"
    }
}

protocol TunnelProcessReclaiming {
    func reclaimStaleProcesses(
        for profile: TunnelProfile,
        configuredPort: Int,
        activePIDs: Set<Int32>
    ) -> TunnelProcessReclaimResult
}

struct TunnelProcessReclaimer: TunnelProcessReclaiming {
    var registry: TunnelProcessRecording = TunnelProcessRegistry()
    var listenerInspector: SocksListenerInspecting = LsofSocksListenerInspector()
    var processController: SSHProcessControlling = DarwinSSHProcessController()
    var terminateGrace: TimeInterval = 1.0
    var killGrace: TimeInterval = 1.0
    var pollInterval: TimeInterval = 0.05

    func reclaimStaleProcesses(
        for profile: TunnelProfile,
        configuredPort: Int,
        activePIDs: Set<Int32>
    ) -> TunnelProcessReclaimResult {
        registry.pruneInactive()
        var result = TunnelProcessReclaimResult()
        var handledPIDs: Set<Int32> = []

        reclaimRegistryBackedProcesses(
            for: profile,
            activePIDs: activePIDs,
            handledPIDs: &handledPIDs,
            result: &result
        )

        reclaimListeners(
            for: profile,
            configuredPort: configuredPort,
            activePIDs: activePIDs,
            handledPIDs: &handledPIDs,
            result: &result
        )

        registry.pruneInactive()
        return result
    }

    private func reclaimRegistryBackedProcesses(
        for profile: TunnelProfile,
        activePIDs: Set<Int32>,
        handledPIDs: inout Set<Int32>,
        result: inout TunnelProcessReclaimResult
    ) {
        for record in registry.records(for: profile.id) {
            guard !activePIDs.contains(record.pid),
                  !handledPIDs.contains(record.pid),
                  processController.processIsRunning(record.pid) else {
                continue
            }

            guard let metadata = processController.metadata(for: record.pid),
                  commandMatches(record: record, metadata: metadata) else {
                registry.remove(profileID: record.profileID, pid: record.pid)
                continue
            }

            handledPIDs.insert(record.pid)
            if terminate(metadata) {
                registry.remove(profileID: record.profileID, pid: record.pid)
                result.reclaimed.append(
                    TunnelProcessReclaimedProcess(
                        pid: record.pid,
                        port: record.effectiveSocksPort,
                        reason: "registered stale tunnel process"
                    )
                )
            } else {
                result.blockers.append(
                    TunnelProcessReclaimBlocker(
                        pid: record.pid,
                        port: record.effectiveSocksPort,
                        reason: "registered stale tunnel process did not exit after SIGTERM/SIGKILL"
                    )
                )
            }
        }
    }

    private func reclaimListeners(
        for profile: TunnelProfile,
        configuredPort: Int,
        activePIDs: Set<Int32>,
        handledPIDs: inout Set<Int32>,
        result: inout TunnelProcessReclaimResult
    ) {
        for listener in listenerInspector.listeners(onLoopbackPort: configuredPort) {
            guard !activePIDs.contains(listener.pid), !handledPIDs.contains(listener.pid) else {
                continue
            }

            guard let metadata = processController.metadata(for: listener.pid),
                  commandMatches(profile: profile, port: configuredPort, metadata: metadata) else {
                result.blockers.append(
                    TunnelProcessReclaimBlocker(
                        pid: listener.pid,
                        port: configuredPort,
                        reason: "listener is not a verified stale SSH AutoTunnel process"
                    )
                )
                continue
            }

            handledPIDs.insert(listener.pid)
            if terminate(metadata) {
                result.reclaimed.append(
                    TunnelProcessReclaimedProcess(
                        pid: listener.pid,
                        port: configuredPort,
                        reason: "matching stale SSH tunnel listener"
                    )
                )
            } else {
                result.blockers.append(
                    TunnelProcessReclaimBlocker(
                        pid: listener.pid,
                        port: configuredPort,
                        reason: "matching stale SSH tunnel listener did not exit after SIGTERM/SIGKILL"
                    )
                )
            }
        }
    }

    private func commandMatches(record: TunnelProcessRecord, metadata: SSHProcessMetadata) -> Bool {
        guard metadata.command.contains(record.executable),
              metadata.command.contains("-N"),
              metadata.command.contains("-D 127.0.0.1:\(record.effectiveSocksPort)") else {
            return false
        }

        guard let destination = record.arguments.last else { return false }
        return metadata.command.contains(destination)
    }

    private func commandMatches(profile: TunnelProfile, port: Int, metadata: SSHProcessMetadata) -> Bool {
        metadata.command.contains("/usr/bin/ssh")
            && metadata.command.contains("-N")
            && metadata.command.contains("-D 127.0.0.1:\(port)")
            && metadata.command.contains("-p \(profile.sshPort)")
            && metadata.command.contains(profile.sshDestination)
    }

    private func terminate(_ metadata: SSHProcessMetadata) -> Bool {
        _ = processController.sendSignal(SIGTERM, toProcessGroup: metadata.processGroupID)
            || processController.sendSignal(SIGTERM, toPID: metadata.pid)
        if waitForExit(pid: metadata.pid, timeout: terminateGrace) {
            return true
        }

        _ = processController.sendSignal(SIGKILL, toProcessGroup: metadata.processGroupID)
            || processController.sendSignal(SIGKILL, toPID: metadata.pid)
        return waitForExit(pid: metadata.pid, timeout: killGrace)
    }

    private func waitForExit(pid: Int32, timeout: TimeInterval) -> Bool {
        let timeout = max(0, timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !processController.processIsRunning(pid) {
                return true
            }
            guard Date() < deadline else {
                return false
            }
            Thread.sleep(forTimeInterval: min(max(0.005, pollInterval), max(0.005, deadline.timeIntervalSinceNow)))
        }
    }
}

struct NoopTunnelProcessReclaimer: TunnelProcessReclaiming {
    func reclaimStaleProcesses(
        for profile: TunnelProfile,
        configuredPort: Int,
        activePIDs: Set<Int32>
    ) -> TunnelProcessReclaimResult {
        TunnelProcessReclaimResult()
    }
}
