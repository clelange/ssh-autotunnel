import Foundation
import SSHAutoTunnelCore

@main
struct SSHAutoTunnelCLI {
    static func main() async {
        do {
            guard let invocation = CLIArguments.parse(Array(CommandLine.arguments.dropFirst())) else {
                printUsage()
                return
            }

            if invocation.command == "profile-template" {
                printProfileTemplate()
                return
            }
            if invocation.command == "pac-rule-template" {
                printPACRuleTemplate()
                return
            }

            let configuration = try ConfigurationStore().load()
            let client = ControlAPIClient(configuration: configuration)
            let response: ControlResponse

            switch invocation.command {
            case "connect":
                response = try await client.send(ControlRequest(action: .connect, profileName: invocation.profileName))
            case "disconnect":
                response = try await client.send(ControlRequest(action: .disconnect, profileName: invocation.profileName))
            case "reconnect":
                response = try await client.send(ControlRequest(action: .reconnect, profileName: invocation.profileName))
            case "status":
                response = try await client.send(ControlRequest(action: .status))
            case "pac-url":
                response = try await client.send(ControlRequest(action: .pacURL))
            case "reload-pac":
                response = try await client.send(ControlRequest(action: .reloadPAC))
            case "apply-system-pac":
                response = try await client.send(ControlRequest(action: .applySystemPAC))
            case "restore-system-proxy":
                response = try await client.send(ControlRequest(action: .restoreSystemPAC))
            case "import-ssh-auto2fa":
                response = try await client.send(ControlRequest(action: .importSSHAuto2FA))
            case "check-ssh-auto2fa":
                response = try await client.send(ControlRequest(action: .checkSSHAuto2FA))
            case "import-ssh-config":
                response = try await client.send(ControlRequest(action: .importSSHConfig))
            case "create-profile":
                let profile = try readProfile(from: invocation.profileName)
                response = try await client.send(ControlRequest(action: .createProfile, profile: profile))
            case "update-profile":
                let profile = try readProfile(from: invocation.profileName)
                response = try await client.send(ControlRequest(action: .updateProfile, profileName: profile.name, profileID: profile.id, profile: profile))
            case "delete-profile":
                response = try await client.send(ControlRequest(action: .deleteProfile, profileName: invocation.profileName))
            case "create-pac-rule":
                let rule = try readPACRule(from: invocation.profileName)
                response = try await client.send(ControlRequest(action: .createPACRule, pacRule: rule))
            case "update-pac-rule":
                let rule = try readPACRule(from: invocation.profileName)
                response = try await client.send(ControlRequest(action: .updatePACRule, pacRuleName: rule.name, pacRuleID: rule.id, pacRule: rule))
            case "delete-pac-rule":
                response = try await client.send(ControlRequest(action: .deletePACRule, pacRuleName: invocation.profileName))
            case "diagnostics":
                response = try await client.send(ControlRequest(action: .diagnostics))
            default:
                printUsage()
                return
            }

            render(response, outputJSON: invocation.outputJSON)
            exit(response.ok ? 0 : 1)
        } catch {
            fputs("ssh-autotunnelctl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func render(_ response: ControlResponse, outputJSON: Bool) {
        if outputJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }

        print(response.message)
        guard let status = response.status else { return }
        print("PAC: \(status.pacURL)")
        if status.proxyDisabledByNetworkPolicy {
            print("Network policy disabled proxy: \(status.matchedNetworkRule ?? "unknown rule")")
        }
        if !status.networkDisabledProfileIDs.isEmpty {
            let disabledProfileNames = status.profiles
                .filter { status.networkDisabledProfileIDs.contains($0.id) }
                .map(\.name)
            print("Network policy disabled profiles: \(disabledProfileNames.isEmpty ? "unknown" : disabledProfileNames.joined(separator: ", "))")
        }
        for profile in status.profiles {
            let pid = profile.pid.map { " pid=\($0)" } ?? ""
            print("- \(profile.name): \(profile.health.rawValue)\(pid) - \(profile.message)")
        }
        if let serviceStatuses = response.sshAuto2FAServiceStatuses {
            print("ssh-auto2fa Keychain services:")
            for serviceStatus in serviceStatuses {
                print("- \(serviceStatus.requirement.profileName) \(serviceStatus.requirement.kind.displayName): \(serviceStatus.requirement.service) - \(label(for: serviceStatus.state))")
            }
        }
        if let diagnostics = response.diagnostics {
            print("Diagnostics:")
            print("- Generated: \(ISO8601DateFormatter().string(from: diagnostics.generatedAt))")
            print("- App: \(diagnostics.appIdentifier)")
            print("- Status URL: \(diagnostics.statusURL)")
            print("- Proxy apply mode: \(diagnostics.proxyApplyMode.rawValue)")
            if let activePorts = diagnostics.activePorts {
                print("- Active ports: PAC \(activePorts.pacHTTPPort), API \(activePorts.apiHTTPPort), blocking proxy \(activePorts.blockingHTTPProxyPort)")
            } else {
                print("- Active ports: none")
            }
            let network = diagnostics.currentNetwork
            let networkParts = [
                network.serviceName.map { "service=\($0)" },
                network.interfaceName.map { "interface=\($0)" },
                network.wifiSSID.map { "ssid=\($0)" },
                network.gateway.map { "gateway=\($0)" },
                "vpn=\(network.hasVPNInterface)"
            ].compactMap(\.self)
            print("- Network: \(networkParts.joined(separator: ", "))")
            print("- System PAC snapshot: \(diagnostics.systemProxySnapshotExists ? "present" : "absent")")
            print("Files:")
            for file in diagnostics.fileStatuses {
                let permissions = file.posixPermissions ?? "n/a"
                print("- \(file.label): \(file.exists ? "exists" : "missing"), mode \(permissions), private=\(file.isPrivate), \(file.path)")
            }
        }
    }

    private static func label(for state: KeychainCredentialState) -> String {
        switch state {
        case .available: "found"
        case .missing: "missing"
        case .unreadable(let message): "unreadable: \(message)"
        }
    }

    private static func readProfile(from argument: String?) throws -> TunnelProfile {
        try readJSON(from: argument, missingMessage: "Profile JSON path is required")
    }

    private static func readPACRule(from argument: String?) throws -> PACRule {
        try readJSON(from: argument, missingMessage: "PAC rule JSON path is required")
    }

    private static func readJSON<T: Decodable>(from argument: String?, missingMessage: String) throws -> T {
        guard let argument, !argument.isEmpty else {
            throw NSError(domain: "ssh-autotunnelctl", code: 2, userInfo: [NSLocalizedDescriptionKey: missingMessage])
        }

        let data: Data
        if argument == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let path = NSString(string: argument).expandingTildeInPath
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func printProfileTemplate() {
        printJSON(ProfileTemplate.example())
    }

    private static func printPACRuleTemplate() {
        printJSON(PACRuleTemplate.example())
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          ssh-autotunnelctl status
          ssh-autotunnelctl status --json
          ssh-autotunnelctl pac-url
          ssh-autotunnelctl reload-pac
          ssh-autotunnelctl apply-system-pac
          ssh-autotunnelctl restore-system-proxy
          ssh-autotunnelctl import-ssh-auto2fa
          ssh-autotunnelctl check-ssh-auto2fa
          ssh-autotunnelctl import-ssh-config
          ssh-autotunnelctl diagnostics --json
          ssh-autotunnelctl profile-template
          ssh-autotunnelctl create-profile <profile.json|->
          ssh-autotunnelctl update-profile <profile.json|->
          ssh-autotunnelctl delete-profile <profile name>
          ssh-autotunnelctl pac-rule-template
          ssh-autotunnelctl create-pac-rule <pac-rule.json|->
          ssh-autotunnelctl update-pac-rule <pac-rule.json|->
          ssh-autotunnelctl delete-pac-rule <PAC rule name>
          ssh-autotunnelctl connect <profile name>
          ssh-autotunnelctl disconnect <profile name>
          ssh-autotunnelctl reconnect <profile name>
        """)
    }
}
