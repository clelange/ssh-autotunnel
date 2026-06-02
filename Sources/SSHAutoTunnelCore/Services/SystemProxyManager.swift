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

public enum SystemPACObservedState: String, Codable, Equatable, Sendable {
    case active
    case staleAutoTunnelPAC
    case notConfigured
    case otherPAC
    case unknown
}

public struct SystemPACStatus: Codable, Equatable, Sendable {
    public var serviceName: String?
    public var expectedPACURL: String
    public var observedPACURL: String?
    public var autoProxyEnabled: Bool?
    public var state: SystemPACObservedState
    public var errorMessage: String?

    public init(
        serviceName: String?,
        expectedPACURL: String,
        observedPACURL: String? = nil,
        autoProxyEnabled: Bool? = nil,
        state: SystemPACObservedState,
        errorMessage: String? = nil
    ) {
        self.serviceName = serviceName
        self.expectedPACURL = expectedPACURL
        self.observedPACURL = observedPACURL
        self.autoProxyEnabled = autoProxyEnabled
        self.state = state
        self.errorMessage = errorMessage
    }

    public static func unknown(
        expectedPACURL: String,
        serviceName: String? = nil,
        errorMessage: String? = nil
    ) -> SystemPACStatus {
        SystemPACStatus(
            serviceName: serviceName,
            expectedPACURL: expectedPACURL,
            state: .unknown,
            errorMessage: errorMessage
        )
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

    public func pacStatus(expectedURL: String) -> SystemPACStatus {
        guard let service = currentServiceName() else {
            return .unknown(
                expectedPACURL: expectedURL,
                errorMessage: SystemProxyManagerError.missingActiveNetworkService.localizedDescription
            )
        }

        let command = NetworkSetupCommand(arguments: ["-getautoproxyurl", service])
        do {
            let result = try commandRunner(command)
            guard result.succeeded else {
                return .unknown(
                    expectedPACURL: expectedURL,
                    serviceName: service,
                    errorMessage: result.proxyStatusErrorMessage
                )
            }
            let snapshot = NetworkSetupParser.autoProxySnapshot(serviceName: service, output: result.stdout)
            return SystemPACStatus(
                serviceName: service,
                expectedPACURL: expectedURL,
                observedPACURL: snapshot.autoProxyURL,
                autoProxyEnabled: snapshot.autoProxyEnabled,
                state: Self.observedState(expectedURL: expectedURL, snapshot: snapshot)
            )
        } catch {
            return .unknown(
                expectedPACURL: expectedURL,
                serviceName: service,
                errorMessage: error.localizedDescription
            )
        }
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

    private static func observedState(expectedURL: String, snapshot: ProxySnapshot) -> SystemPACObservedState {
        guard snapshot.autoProxyEnabled else { return .notConfigured }
        guard let observedURL = snapshot.autoProxyURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !observedURL.isEmpty else {
            return .otherPAC
        }
        let expected = expectedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if observedURL == expected {
            return .active
        }
        if normalizedPACURL(observedURL) == normalizedPACURL(expected) {
            return .staleAutoTunnelPAC
        }
        return .otherPAC
    }

    private static func normalizedPACURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? value
    }
}

extension ProxySnapshotStore: ProxySnapshotStoring {}

private extension ShellResult {
    var proxyStatusErrorMessage: String {
        let stderrMessage = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrMessage.isEmpty {
            return stderrMessage
        }
        let stdoutMessage = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdoutMessage.isEmpty {
            return stdoutMessage
        }
        return "networksetup exited with status \(exitCode)"
    }
}
