import Foundation

public struct NetworkSetupCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String = "/usr/sbin/networksetup", arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum NetworkSetupParser {
    public static func autoProxySnapshot(serviceName: String, output: String) -> ProxySnapshot {
        var enabled = false
        var url: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = value(in: line, after: "URL:") {
                url = value.isEmpty || value == "(null)" ? nil : value
            } else if let value = value(in: line, after: "Enabled:") {
                enabled = ["1", "yes", "on", "true"].contains(value.lowercased())
            }
        }

        return ProxySnapshot(serviceName: serviceName, autoProxyEnabled: enabled, autoProxyURL: url)
    }

    public static func serviceName(forDevice device: String, hardwarePortsOutput: String) -> String? {
        var currentHardwarePort: String?

        for rawLine in hardwarePortsOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hardwarePort = value(in: line, after: "Hardware Port:") {
                currentHardwarePort = hardwarePort
            } else if let currentDevice = value(in: line, after: "Device:"), currentDevice == device {
                return currentHardwarePort
            }
        }

        return nil
    }

    public static func serviceName(forDevice device: String, serviceOrderOutput: String) -> String? {
        var currentServiceName: String?

        for rawLine in serviceOrderOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let serviceName = serviceName(inServiceOrderLine: line) {
                currentServiceName = serviceName
            } else if let currentDevice = serviceOrderDevice(in: line), currentDevice == device {
                return currentServiceName
            }
        }

        return nil
    }

    private static func value(in line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func serviceName(inServiceOrderLine line: String) -> String? {
        guard line.hasPrefix("("),
              let markerEnd = line.firstIndex(of: ")") else {
            return nil
        }
        let markerStart = line.index(after: line.startIndex)
        let marker = line[markerStart..<markerEnd]
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard Int(marker) != nil else { return nil }

        let nameStart = line.index(after: markerEnd)
        let name = line[nameStart...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingPrefix("*")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func serviceOrderDevice(in line: String) -> String? {
        guard line.hasPrefix("(Hardware Port:"),
              let range = line.range(of: "Device:") else {
            return nil
        }
        var device = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if device.hasSuffix(")") {
            device.removeLast()
        }
        let trimmed = device.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum SystemProxyPlanner {
    public static func applyPACCommands(serviceName: String, pacURL: String) -> [NetworkSetupCommand] {
        [
            NetworkSetupCommand(arguments: ["-setautoproxyurl", serviceName, pacURL]),
            NetworkSetupCommand(arguments: ["-setautoproxystate", serviceName, "on"])
        ]
    }

    public static func restoreCommands(snapshot: ProxySnapshot) -> [NetworkSetupCommand] {
        var commands: [NetworkSetupCommand] = []

        if let autoProxyURL = snapshot.autoProxyURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !autoProxyURL.isEmpty {
            commands.append(NetworkSetupCommand(arguments: ["-setautoproxyurl", snapshot.serviceName, autoProxyURL]))
        }

        commands.append(NetworkSetupCommand(arguments: [
            "-setautoproxystate",
            snapshot.serviceName,
            snapshot.autoProxyEnabled ? "on" : "off"
        ]))

        return commands
    }
}
