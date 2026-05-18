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
    }

    private static func label(for state: KeychainCredentialState) -> String {
        switch state {
        case .available: "found"
        case .missing: "missing"
        case .unreadable(let message): "unreadable: \(message)"
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
          ssh-autotunnelctl connect <profile name>
          ssh-autotunnelctl disconnect <profile name>
          ssh-autotunnelctl reconnect <profile name>
        """)
    }
}
