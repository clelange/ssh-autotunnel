import CoreWLAN
import Foundation

public final class NetworkIdentityService {
    public init() {}

    public func currentFingerprint() -> NetworkFingerprint {
        let interfaceName = defaultInterface()
        return NetworkFingerprint(
            interfaceName: interfaceName,
            serviceName: interfaceName.flatMap { serviceName(forDevice: $0) },
            wifiSSID: currentWiFiSSID(),
            wifiBSSID: currentWiFiBSSID(),
            gateway: defaultGateway(),
            dnsServers: dnsServers(),
            searchDomains: searchDomains(),
            ipv4Addresses: ipv4Addresses(),
            hasVPNInterface: hasVPNInterface()
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

    private func currentWiFiSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    private func currentWiFiBSSID() -> String? {
        CWWiFiClient.shared().interface()?.bssid()
    }

    private func defaultInterface() -> String? {
        guard let result = try? ShellRunner.run("/usr/sbin/route", ["-n", "get", "default"]), result.succeeded else {
            return nil
        }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("interface:") else { return nil }
                return trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
            .first
    }

    private func defaultGateway() -> String? {
        guard let result = try? ShellRunner.run("/usr/sbin/route", ["-n", "get", "default"]), result.succeeded else {
            return nil
        }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("gateway:") else { return nil }
                return trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
            .first
    }

    private func serviceName(forDevice device: String) -> String? {
        guard let result = try? ShellRunner.run("/usr/sbin/networksetup", ["-listallhardwareports"]), result.succeeded else {
            return nil
        }
        var currentHardwarePort: String?
        for rawLine in result.stdout.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("Hardware Port:") {
                currentHardwarePort = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                let currentDevice = line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if currentDevice == device {
                    return currentHardwarePort
                }
            }
        }
        return nil
    }

    private func dnsServers() -> [String] {
        guard let result = try? ShellRunner.run("/usr/sbin/scutil", ["--dns"]), result.succeeded else {
            return []
        }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("nameserver[") else { return nil }
                return trimmed.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
            }
    }

    private func searchDomains() -> [String] {
        guard let result = try? ShellRunner.run("/usr/sbin/scutil", ["--dns"]), result.succeeded else {
            return []
        }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("search domain[") || trimmed.hasPrefix("domain   :") else { return nil }
                return trimmed.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
            }
    }

    private func ipv4Addresses() -> [String] {
        guard let result = try? ShellRunner.run("/sbin/ifconfig", []), result.succeeded else {
            return []
        }
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("inet ") else { return nil }
                return trimmed.split(separator: " ").dropFirst().first.map(String.init)
            }
    }

    private func hasVPNInterface() -> Bool {
        guard let result = try? ShellRunner.run("/sbin/ifconfig", []), result.succeeded else {
            return false
        }
        return result.stdout.split(separator: "\n").contains { line in
            line.hasPrefix("utun") || line.hasPrefix("ppp") || line.hasPrefix("ipsec")
        }
    }
}
