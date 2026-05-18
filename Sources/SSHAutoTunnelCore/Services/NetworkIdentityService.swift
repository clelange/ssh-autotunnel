import CoreWLAN
import Foundation

public enum NetworkIdentityParser {
    public static func defaultInterface(routeOutput: String) -> String? {
        value(in: routeOutput, after: "interface:")
    }

    public static func defaultGateway(routeOutput: String) -> String? {
        value(in: routeOutput, after: "gateway:")
    }

    public static func dnsServers(scutilDNSOutput: String) -> [String] {
        values(in: scutilDNSOutput) { line in
            guard line.hasPrefix("nameserver[") else { return nil }
            return line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
        }
    }

    public static func searchDomains(scutilDNSOutput: String) -> [String] {
        values(in: scutilDNSOutput) { line in
            guard line.hasPrefix("search domain[") || line.hasPrefix("domain   :") else { return nil }
            return line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
        }
    }

    public static func ipv4Addresses(ifconfigOutput: String) -> [String] {
        values(in: ifconfigOutput) { line in
            guard line.hasPrefix("inet ") else { return nil }
            return line.split(separator: " ").dropFirst().first.map(String.init)
        }
    }

    public static func hasVPNInterface(ifconfigOutput: String) -> Bool {
        ifconfigOutput.split(separator: "\n").contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("utun") || line.hasPrefix("ppp") || line.hasPrefix("ipsec")
        }
    }

    private static func value(in output: String, after prefix: String) -> String? {
        values(in: output) { line in
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }.first
    }

    private static func values(in output: String, transform: (String) -> String?) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                return transform(trimmed)?.nonEmptyTrimmed
            }
    }
}

public final class NetworkIdentityService {
    private let commandRunner: (String, [String]) throws -> ShellResult
    private let wifiSSIDProvider: () -> String?
    private let wifiBSSIDProvider: () -> String?

    public convenience init() {
        self.init(
            commandRunner: ShellRunner.run,
            wifiSSIDProvider: { CWWiFiClient.shared().interface()?.ssid() },
            wifiBSSIDProvider: { CWWiFiClient.shared().interface()?.bssid() }
        )
    }

    init(
        commandRunner: @escaping (String, [String]) throws -> ShellResult,
        wifiSSIDProvider: @escaping () -> String?,
        wifiBSSIDProvider: @escaping () -> String?
    ) {
        self.commandRunner = commandRunner
        self.wifiSSIDProvider = wifiSSIDProvider
        self.wifiBSSIDProvider = wifiBSSIDProvider
    }

    public func currentFingerprint() -> NetworkFingerprint {
        let routeOutput = successfulOutput("/usr/sbin/route", ["-n", "get", "default"])
        let scutilDNSOutput = successfulOutput("/usr/sbin/scutil", ["--dns"])
        let ifconfigOutput = successfulOutput("/sbin/ifconfig", [])
        let interfaceName = routeOutput.flatMap { NetworkIdentityParser.defaultInterface(routeOutput: $0) }

        return NetworkFingerprint(
            interfaceName: interfaceName,
            serviceName: interfaceName.flatMap { serviceName(forDevice: $0) },
            wifiSSID: wifiSSIDProvider(),
            wifiBSSID: wifiBSSIDProvider(),
            gateway: routeOutput.flatMap { NetworkIdentityParser.defaultGateway(routeOutput: $0) },
            dnsServers: scutilDNSOutput.map { NetworkIdentityParser.dnsServers(scutilDNSOutput: $0) } ?? [],
            searchDomains: scutilDNSOutput.map { NetworkIdentityParser.searchDomains(scutilDNSOutput: $0) } ?? [],
            ipv4Addresses: ifconfigOutput.map { NetworkIdentityParser.ipv4Addresses(ifconfigOutput: $0) } ?? [],
            hasVPNInterface: ifconfigOutput.map { NetworkIdentityParser.hasVPNInterface(ifconfigOutput: $0) } ?? false
        )
    }

    public func evaluate(configuration: AppConfiguration) -> NetworkPolicyDecision {
        let fingerprint = currentFingerprint()
        return evaluate(configuration: configuration, fingerprint: fingerprint)
    }

    public func evaluate(configuration: AppConfiguration, fingerprint: NetworkFingerprint) -> NetworkPolicyDecision {
        for rule in configuration.networkRules where rule.enabled {
            if rule.match.matches(fingerprint) {
                return NetworkPolicyDecision(shouldDisableProxy: rule.action == .disableProxy, matchedRule: rule)
            }
        }
        return NetworkPolicyDecision(shouldDisableProxy: false, matchedRule: nil)
    }

    private func serviceName(forDevice device: String) -> String? {
        guard let output = successfulOutput("/usr/sbin/networksetup", ["-listallhardwareports"]) else {
            return nil
        }
        return NetworkSetupParser.serviceName(forDevice: device, hardwarePortsOutput: output)
    }

    private func successfulOutput(_ executable: String, _ arguments: [String]) -> String? {
        guard let result = try? commandRunner(executable, arguments), result.succeeded else { return nil }
        return result.stdout
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
