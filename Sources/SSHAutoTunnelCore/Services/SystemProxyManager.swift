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
    func save(_ snapshot: ProxySnapshot) throws
    func load() throws -> ProxySnapshot?
    func clear() throws
}

public final class SystemProxyManager {
    private let snapshotStore: ProxySnapshotStoring?
    private let currentServiceName: () -> String?
    private let commandRunner: (NetworkSetupCommand) throws -> ShellResult
    private var snapshot: ProxySnapshot?

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
        if snapshot == nil || snapshot?.serviceName != service {
            let currentSnapshot = currentAutoProxySnapshot(serviceName: service)
            try snapshotStore?.save(currentSnapshot)
            snapshot = currentSnapshot
        }
        for command in SystemProxyPlanner.applyPACCommands(serviceName: service, pacURL: url) {
            _ = try commandRunner(command)
        }
        return service
    }

    public func restoreIfNeeded() throws {
        let snapshotToRestore: ProxySnapshot?
        if let snapshot {
            snapshotToRestore = snapshot
        } else {
            snapshotToRestore = try snapshotStore?.load()
        }
        guard let snapshot = snapshotToRestore else { return }
        for command in SystemProxyPlanner.restoreCommands(snapshot: snapshot) {
            _ = try commandRunner(command)
        }
        self.snapshot = nil
        try snapshotStore?.clear()
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
