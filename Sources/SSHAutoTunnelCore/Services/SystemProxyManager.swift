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
        _ = try ShellRunner.run("/usr/sbin/networksetup", ["-setautoproxyurl", service, url])
        _ = try ShellRunner.run("/usr/sbin/networksetup", ["-setautoproxystate", service, "on"])
        return service
    }

    public func restoreIfNeeded() throws {
        guard let snapshot else { return }
        if let autoProxyURL = snapshot.autoProxyURL, !autoProxyURL.isEmpty {
            _ = try ShellRunner.run("/usr/sbin/networksetup", ["-setautoproxyurl", snapshot.serviceName, autoProxyURL])
        }
        _ = try ShellRunner.run("/usr/sbin/networksetup", ["-setautoproxystate", snapshot.serviceName, snapshot.autoProxyEnabled ? "on" : "off"])
        self.snapshot = nil
    }

    private func currentAutoProxySnapshot(serviceName: String) -> ProxySnapshot {
        guard let result = try? ShellRunner.run("/usr/sbin/networksetup", ["-getautoproxyurl", serviceName]), result.succeeded else {
            return ProxySnapshot(serviceName: serviceName, autoProxyEnabled: false, autoProxyURL: nil)
        }

        var enabled = false
        var url: String?
        for rawLine in result.stdout.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("URL:") {
                url = line.replacingOccurrences(of: "URL:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Enabled:") {
                let value = line.replacingOccurrences(of: "Enabled:", with: "").trimmingCharacters(in: .whitespaces)
                enabled = value == "Yes" || value == "1"
            }
        }
        return ProxySnapshot(serviceName: serviceName, autoProxyEnabled: enabled, autoProxyURL: url)
    }
}
