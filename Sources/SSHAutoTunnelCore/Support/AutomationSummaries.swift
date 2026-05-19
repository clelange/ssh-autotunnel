import Foundation

public enum AutomationSummaries {
    public static func networkActionName(_ action: NetworkPolicyAction) -> String {
        switch action {
        case .disableProxy:
            "Disable proxy"
        case .allowProxy:
            "Allow proxy"
        }
    }

    public static func networkMatchSummary(_ match: NetworkMatch) -> String {
        [
            match.wifiSSID.map { "Wi-Fi SSID \($0)" },
            match.wifiBSSID.map { "Wi-Fi BSSID \($0)" },
            match.serviceNameContains.map { "service contains \($0)" },
            match.searchDomainContains.map { "search domain contains \($0)" },
            match.gateway.map { "gateway \($0)" },
            match.vpnRequired.map { "VPN \($0 ? "required" : "absent")" }
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
    }

    public static func currentNetworkSummary(_ fingerprint: NetworkFingerprint) -> String {
        [
            fingerprint.serviceName.map { "service=\($0)" },
            fingerprint.interfaceName.map { "interface=\($0)" },
            fingerprint.wifiSSID.map { "ssid=\($0)" },
            fingerprint.wifiBSSID.map { "bssid=\($0)" },
            fingerprint.gateway.map { "gateway=\($0)" },
            fingerprint.dnsServers.isEmpty ? nil : "dns=\(fingerprint.dnsServers.joined(separator: ","))",
            fingerprint.searchDomains.isEmpty ? nil : "searchDomains=\(fingerprint.searchDomains.joined(separator: ","))",
            fingerprint.ipv4Addresses.isEmpty ? nil : "ipv4=\(fingerprint.ipv4Addresses.joined(separator: ","))",
            "vpn=\(fingerprint.hasVPNInterface)"
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
    }
}
