import Foundation

public struct ProxySnapshot: Codable, Equatable, Sendable {
    public var serviceName: String
    public var autoProxyEnabled: Bool
    public var autoProxyURL: String?
}

public enum SystemProxyManagerError: LocalizedError, Equatable {
    case missingActiveNetworkService

    public var errorDescription: String? {
        switch self {
        case .missingActiveNetworkService:
            "Could not determine active network service"
        }
    }
}

protocol ProxySnapshotStoring: AnyObject {
    func saveAll(_ snapshots: [ProxySnapshot]) throws
    func loadAll() throws -> [ProxySnapshot]
    func clear() throws
}

public final class SystemProxyManager {
    private let snapshotStore: ProxySnapshotStoring?
    private let currentServiceName: () -> String?
    private let commandRunner: (NetworkSetupCommand) throws -> ShellResult
    private var snapshotsByService: [String: ProxySnapshot] = [:]
    private var didLoadSnapshots = false

    public convenience init(snapshotStore: ProxySnapshotStore? = nil) {
        let networkIdentity = NetworkIdentityService()
        self.init(
            snapshotStore: snapshotStore ?? (try? ProxySnapshotStore()),
            currentServiceName: { networkIdentity.currentFingerprint().serviceName },
            commandRunner: { command in
                try ShellRunner.run(command.executable, command.arguments)
            }
        )
    }

    init(
        snapshotStore: ProxySnapshotStoring?,
        currentServiceName: @escaping () -> String?,
        commandRunner: @escaping (NetworkSetupCommand) throws -> ShellResult
    ) {
        self.snapshotStore = snapshotStore
        self.currentServiceName = currentServiceName
        self.commandRunner = commandRunner
    }

    public func applyPAC(url: String) throws -> String {
        guard let service = currentServiceName() else {
            throw SystemProxyManagerError.missingActiveNetworkService
        }
        try loadSnapshotsIfNeeded()
        if snapshotsByService[service] == nil {
            let currentSnapshot = currentAutoProxySnapshot(serviceName: service)
            snapshotsByService[service] = currentSnapshot
            try snapshotStore?.saveAll(sortedSnapshots())
        }
        for command in SystemProxyPlanner.applyPACCommands(serviceName: service, pacURL: url) {
            _ = try commandRunner(command)
        }
        return service
    }

    public func restoreIfNeeded() throws {
        try loadSnapshotsIfNeeded()
        let snapshots = sortedSnapshots()
        guard !snapshots.isEmpty else { return }
        for snapshot in snapshots {
            for command in SystemProxyPlanner.restoreCommands(snapshot: snapshot) {
                _ = try commandRunner(command)
            }
        }
        snapshotsByService.removeAll()
        try snapshotStore?.clear()
    }

    private func loadSnapshotsIfNeeded() throws {
        guard !didLoadSnapshots else { return }
        let snapshots = try snapshotStore?.loadAll() ?? []
        snapshotsByService = [:]
        for snapshot in snapshots {
            snapshotsByService[snapshot.serviceName] = snapshot
        }
        didLoadSnapshots = true
    }

    private func sortedSnapshots() -> [ProxySnapshot] {
        snapshotsByService.values.sorted { $0.serviceName < $1.serviceName }
    }

    private func currentAutoProxySnapshot(serviceName: String) -> ProxySnapshot {
        let command = NetworkSetupCommand(arguments: ["-getautoproxyurl", serviceName])
        guard let result = try? commandRunner(command), result.succeeded else {
            return ProxySnapshot(serviceName: serviceName, autoProxyEnabled: false, autoProxyURL: nil)
        }

        return NetworkSetupParser.autoProxySnapshot(serviceName: serviceName, output: result.stdout)
    }
}

extension ProxySnapshotStore: ProxySnapshotStoring {}
