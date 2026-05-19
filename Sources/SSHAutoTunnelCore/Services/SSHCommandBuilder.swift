import Foundation

public struct SSHCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String = "/usr/bin/ssh", arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum SSHCommandBuilder {
    public static func tunnelCommand(for profile: TunnelProfile) -> SSHCommand {
        var arguments = [
            "-N",
            "-D", "127.0.0.1:\(profile.localSocksPort)",
            "-p", "\(profile.sshPort)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2"
        ]

        if let strictHostKeyCheckingValue = profile.hostKeyPolicy.strictHostKeyCheckingValue {
            arguments += ["-o", "StrictHostKeyChecking=\(strictHostKeyCheckingValue)"]
        }

        if usesKeyboardInteractiveAuth(profile.authMode) {
            arguments += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }

        if let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines), !jumpHost.isEmpty {
            arguments += ["-J", jumpHost]
        }

        arguments += profile.extraSSHOptions
        arguments.append(profile.sshDestination)
        return SSHCommand(arguments: arguments)
    }

    private static func usesKeyboardInteractiveAuth(_ authMode: TunnelAuthMode) -> Bool {
        switch authMode {
        case .password, .passwordAndTOTP:
            return true
        case .none, .totp, .kerberosAndTOTP:
            return false
        }
    }
}
