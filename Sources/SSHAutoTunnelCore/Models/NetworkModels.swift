import Foundation

public struct NetworkFingerprint: Codable, Equatable, Sendable {
    public var interfaceName: String?
    public var serviceName: String?
    public var wifiSSID: String?
    public var wifiBSSID: String?
    public var gateway: String?
    public var dnsServers: [String]
    public var searchDomains: [String]
    public var ipv4Addresses: [String]
    public var hasVPNInterface: Bool

    public init(
        interfaceName: String? = nil,
        serviceName: String? = nil,
        wifiSSID: String? = nil,
        wifiBSSID: String? = nil,
        gateway: String? = nil,
        dnsServers: [String] = [],
        searchDomains: [String] = [],
        ipv4Addresses: [String] = [],
        hasVPNInterface: Bool = false
    ) {
        self.interfaceName = interfaceName
        self.serviceName = serviceName
        self.wifiSSID = wifiSSID
        self.wifiBSSID = wifiBSSID
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.searchDomains = searchDomains
        self.ipv4Addresses = ipv4Addresses
        self.hasVPNInterface = hasVPNInterface
    }
}

public enum NetworkPolicyAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case disableProxy
    case allowProxy

    public var id: String { rawValue }
}

public struct NetworkMatch: Codable, Equatable, Sendable {
    public var wifiSSID: String?
    public var wifiBSSID: String?
    public var serviceNameContains: String?
    public var searchDomainContains: String?
    public var gateway: String?
    public var vpnRequired: Bool?

    public init(
        wifiSSID: String? = nil,
        wifiBSSID: String? = nil,
        serviceNameContains: String? = nil,
        searchDomainContains: String? = nil,
        gateway: String? = nil,
        vpnRequired: Bool? = nil
    ) {
        self.wifiSSID = wifiSSID
        self.wifiBSSID = wifiBSSID
        self.serviceNameContains = serviceNameContains
        self.searchDomainContains = searchDomainContains
        self.gateway = gateway
        self.vpnRequired = vpnRequired
    }

    public func matches(_ fingerprint: NetworkFingerprint) -> Bool {
        if let wifiSSID, fingerprint.wifiSSID != wifiSSID { return false }
        if let wifiBSSID, fingerprint.wifiBSSID?.lowercased() != wifiBSSID.lowercased() { return false }
        if let serviceNameContains {
            guard fingerprint.serviceName?.localizedCaseInsensitiveContains(serviceNameContains) == true else { return false }
        }
        if let searchDomainContains {
            guard fingerprint.searchDomains.contains(where: { $0.localizedCaseInsensitiveContains(searchDomainContains) }) else { return false }
        }
        if let gateway, fingerprint.gateway != gateway { return false }
        if let vpnRequired, fingerprint.hasVPNInterface != vpnRequired { return false }
        return true
    }
}

public struct NetworkPolicyRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: NetworkMatch
    public var action: NetworkPolicyAction

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        match: NetworkMatch,
        action: NetworkPolicyAction
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.action = action
    }

    public static func disableProxyRule(from fingerprint: NetworkFingerprint) -> NetworkPolicyRule? {
        if let ssid = fingerprint.wifiSSID?.nonEmptyTrimmed {
            return NetworkPolicyRule(
                name: "Trusted Wi-Fi: \(ssid)",
                match: NetworkMatch(wifiSSID: ssid),
                action: .disableProxy
            )
        }

        if let searchDomain = fingerprint.searchDomains.compactMap(\.nonEmptyTrimmed).first {
            return NetworkPolicyRule(
                name: "Trusted domain: \(searchDomain)",
                match: NetworkMatch(searchDomainContains: searchDomain),
                action: .disableProxy
            )
        }

        if let serviceName = fingerprint.serviceName?.nonEmptyTrimmed {
            return NetworkPolicyRule(
                name: "Trusted service: \(serviceName)",
                match: NetworkMatch(serviceNameContains: serviceName),
                action: .disableProxy
            )
        }

        if let gateway = fingerprint.gateway?.nonEmptyTrimmed {
            return NetworkPolicyRule(
                name: "Trusted gateway: \(gateway)",
                match: NetworkMatch(gateway: gateway),
                action: .disableProxy
            )
        }

        if fingerprint.hasVPNInterface {
            return NetworkPolicyRule(
                name: "Trusted VPN",
                match: NetworkMatch(vpnRequired: true),
                action: .disableProxy
            )
        }

        return nil
    }
}

public struct NetworkPolicyDecision: Equatable, Sendable {
    public var shouldDisableProxy: Bool
    public var matchedRule: NetworkPolicyRule?

    public init(shouldDisableProxy: Bool, matchedRule: NetworkPolicyRule?) {
        self.shouldDisableProxy = shouldDisableProxy
        self.matchedRule = matchedRule
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
