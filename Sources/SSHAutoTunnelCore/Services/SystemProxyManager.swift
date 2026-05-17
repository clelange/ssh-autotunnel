import Foundation

public struct ProxySnapshot: Codable, Equatable, Sendable {
    public var serviceName: String
    public var autoProxyEnabled: Bool
    public var autoProxyURL: String?
}

public final class SystemProxyManager {
    private let networkIdentity = NetworkIdentityService()
    private var snapshot: ProxySnapshot?

    public init() {}

    public func applyPAC(url: String) throws -> String {
        guard let service = networkIdentity.currentFingerprint().serviceName else {
            throw NSError(domain: "SystemProxyManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not determine active network service"])
        }
        if snapshot == nil || snapshot?.serviceName != service {
            snapshot = currentAutoProxySnapshot(serviceName: service)
        }
        for command in SystemProxyPlanner.applyPACCommands(serviceName: service, pacURL: url) {
            _ = try ShellRunner.run(command.executable, command.arguments)
        }
        return service
    }

    public func restoreIfNeeded() throws {
        guard let snapshot else { return }
        for command in SystemProxyPlanner.restoreCommands(snapshot: snapshot) {
            _ = try ShellRunner.run(command.executable, command.arguments)
        }
        self.snapshot = nil
    }

    private func currentAutoProxySnapshot(serviceName: String) -> ProxySnapshot {
        guard let result = try? ShellRunner.run("/usr/sbin/networksetup", ["-getautoproxyurl", serviceName]), result.succeeded else {
            return ProxySnapshot(serviceName: serviceName, autoProxyEnabled: false, autoProxyURL: nil)
        }

        return NetworkSetupParser.autoProxySnapshot(serviceName: serviceName, output: result.stdout)
    }
}
