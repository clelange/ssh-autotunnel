import Foundation
import SSHAutoTunnelCore

@main
struct SSHAutoTunnelCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else {
                printUsage()
                return
            }

            let configuration = try ConfigurationStore().load()
            let client = ControlAPIClient(configuration: configuration)
            let response: ControlResponse

            switch command {
            case "connect":
                response = try await client.send(ControlRequest(action: .connect, profileName: profileName(from: args)))
            case "disconnect":
                response = try await client.send(ControlRequest(action: .disconnect, profileName: profileName(from: args)))
            case "reconnect":
                response = try await client.send(ControlRequest(action: .reconnect, profileName: profileName(from: args)))
            case "status":
                response = try await client.send(ControlRequest(action: .status))
            case "pac-url":
                response = try await client.send(ControlRequest(action: .pacURL))
            case "reload-pac":
                response = try await client.send(ControlRequest(action: .reloadPAC))
            default:
                printUsage()
                return
            }

            render(response)
            exit(response.ok ? 0 : 1)
        } catch {
            fputs("ssh-autotunnelctl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func profileName(from args: [String]) -> String? {
        let remainder = args.dropFirst()
        guard !remainder.isEmpty else { return nil }
        return remainder.joined(separator: " ")
    }

    private static func render(_ response: ControlResponse) {
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
    }

    private static func printUsage() {
        print("""
        Usage:
          ssh-autotunnelctl status
          ssh-autotunnelctl pac-url
          ssh-autotunnelctl reload-pac
          ssh-autotunnelctl connect <profile name>
          ssh-autotunnelctl disconnect <profile name>
          ssh-autotunnelctl reconnect <profile name>
        """)
    }
}
