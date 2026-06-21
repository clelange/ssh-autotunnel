import Foundation

public struct PortConfigurationError: LocalizedError, Equatable, Sendable {
    public var messages: [String]

    public var errorDescription: String? {
        "Invalid port configuration: \(messages.joined(separator: "; "))"
    }
}

public enum PortConfigurationValidator {
    public static let validRange = 1...65_535

    public static func validate(_ configuration: AppConfiguration) throws {
        let messages = validationMessages(for: configuration)
        if !messages.isEmpty {
            throw PortConfigurationError(messages: messages)
        }
    }

    public static func validationMessages(for configuration: AppConfiguration) -> [String] {
        var messages: [String] = []
        var reservedPorts: [Int: [String]] = [:]

        func validatePort(_ port: Int, label: String, mustBeUnique: Bool = false) {
            if !validRange.contains(port) {
                messages.append("\(label) must be between 1 and 65535")
                return
            }
            if mustBeUnique {
                reservedPorts[port, default: []].append(label)
            }
        }

        validatePort(configuration.pacHTTPPort, label: "PAC HTTP port", mustBeUnique: true)
        validatePort(configuration.apiHTTPPort, label: "API HTTP port", mustBeUnique: true)
        validatePort(configuration.blockingHTTPProxyPort, label: "Blocking proxy port", mustBeUnique: true)

        for profile in configuration.profiles {
            validatePort(profile.sshPort, label: "\(profile.name) SSH port")
            validatePort(profile.localSocksPort, label: "\(profile.name) local SOCKS port", mustBeUnique: true)
            if let healthProbe = profile.healthProbe {
                validatePort(healthProbe.port, label: "\(profile.name) health probe port")
            }
            for forwarding in profile.localPortForwardings where forwarding.enabled {
                validatePort(forwarding.localPort, label: "\(profile.name) local forward source port", mustBeUnique: true)
                validatePort(forwarding.targetPort, label: "\(profile.name) local forward target port")
            }
        }

        for (port, labels) in reservedPorts where labels.count > 1 {
            messages.append("Port \(port) is used by \(labels.joined(separator: ", "))")
        }

        return messages
    }
}
