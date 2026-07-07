import Foundation

public struct SSHCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String = "/usr/bin/ssh", arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var shellCommand: String {
        ([executable] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    public static func shellQuoted(_ value: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+-=.,/:@%")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum SSHCommandBuilder {
    public static func tunnelCommand(for profile: TunnelProfile, options: SSHLaunchOptions = .standard) -> SSHCommand {
        var arguments: [String] = []
        if !profile.tunnelRequestsRemoteSession {
            arguments.append("-N")
        }
        arguments += [
            "-F", "none",
            "-D", "127.0.0.1:\(profile.localSocksPort)",
            "-p", "\(profile.sshPort)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ForkAfterAuthentication=no",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2"
        ]
        appendControlMasterSuppression(to: &arguments)

        if let strictHostKeyCheckingValue = profile.hostKeyPolicy.strictHostKeyCheckingValue {
            arguments += ["-o", "StrictHostKeyChecking=\(strictHostKeyCheckingValue)"]
        }

        if usesKeyboardInteractiveAuth(profile.authMode) {
            arguments += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }

        if usesKerberosAuth(profile.authMode) {
            arguments += [
                "-o", "GSSAPIAuthentication=yes",
                "-o", "PreferredAuthentications=gssapi-with-mic,keyboard-interactive",
                "-o", "PasswordAuthentication=no"
            ]
        }

        appendCuratedOptions(profile, to: &arguments)
        appendLocalPortForwardings(profile, to: &arguments)

        let proxyCommand = profile.curatedSSHOptions.proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proxyCommand.isEmpty,
           let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jumpHost.isEmpty {
            arguments += ["-J", jumpHost]
        }

        appendLaunchOptions(options, profile: profile, to: &arguments)
        arguments += profile.extraSSHOptions
        arguments.append(profile.sshDestination)
        return SSHCommand(arguments: arguments)
    }

    public static func interactiveCommand(for profile: TunnelProfile, options: SSHLaunchOptions = .standard) -> SSHCommand {
        var profile = profile
        profile.host = profile.resolvedInteractiveHost
        var arguments = [
            "-p", "\(profile.sshPort)"
        ]
        appendControlMasterSuppression(to: &arguments)
        appendForwardingSuppression(to: &arguments)

        if let strictHostKeyCheckingValue = profile.hostKeyPolicy.strictHostKeyCheckingValue {
            arguments += ["-o", "StrictHostKeyChecking=\(strictHostKeyCheckingValue)"]
        }

        if usesKeyboardInteractiveAuth(profile.authMode) {
            arguments += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }

        if usesKerberosAuth(profile.authMode) {
            arguments += [
                "-o", "GSSAPIAuthentication=yes",
                "-o", "PreferredAuthentications=gssapi-with-mic,keyboard-interactive",
                "-o", "PasswordAuthentication=no"
            ]
        }

        appendCuratedOptions(profile, to: &arguments)

        let proxyCommand = profile.curatedSSHOptions.proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proxyCommand.isEmpty,
           let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jumpHost.isEmpty {
            arguments += ["-J", jumpHost]
        }

        appendLaunchOptions(options, profile: profile, to: &arguments)
        arguments += profile.extraSSHOptions
        arguments.append(profile.sshDestination)
        return SSHCommand(arguments: arguments)
    }

    private static func appendCuratedOptions(_ profile: TunnelProfile, to arguments: inout [String]) {
        let sshOptions = profile.curatedSSHOptions

        if let bindAddress = trimmed(sshOptions.bindAddress) {
            arguments += ["-b", bindAddress]
        }

        if sshOptions.addressFamily != .any {
            arguments += ["-o", "AddressFamily=\(sshOptions.addressFamily.sshValue)"]
        }

        if let compression = sshOptions.compression.sshYesNoValue {
            arguments += ["-o", "Compression=\(compression)"]
        }

        for identityFile in sshOptions.identityFiles.compactMap(trimmed) {
            arguments += ["-i", identityFile]
        }

        for certificateFile in sshOptions.certificateFiles.compactMap(trimmed) {
            arguments += ["-o", "CertificateFile=\(certificateFile)"]
        }

        if let forwardAgent = sshOptions.forwardAgent.sshYesNoValue {
            arguments += ["-o", "ForwardAgent=\(forwardAgent)"]
        }

        if let proxyCommand = trimmed(sshOptions.proxyCommand) {
            arguments += ["-o", "ProxyCommand=\(proxyCommand)"]
        }
    }

    private static func appendLocalPortForwardings(_ profile: TunnelProfile, to arguments: inout [String]) {
        for forwarding in profile.localPortForwardings where forwarding.enabled {
            arguments += ["-L", forwarding.sshArgument]
        }
    }

    private static func appendControlMasterSuppression(to arguments: inout [String]) {
        arguments += [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no"
        ]
    }

    static func appendForwardingSuppression(to arguments: inout [String]) {
        arguments += ["-o", "ClearAllForwardings=yes"]
    }

    static func appendLaunchOptions(_ options: SSHLaunchOptions, profile: TunnelProfile, to arguments: inout [String]) {
        if options.verbose, !arguments.contains("-vvv") {
            arguments.append("-vvv")
        }
        let logLevel: SSHLogLevel = options.verbose ? .debug3 : profile.sshLogLevel
        if logLevel != .info {
            arguments += ["-o", "LogLevel=\(logLevel.sshValue)"]
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func usesKeyboardInteractiveAuth(_ authMode: TunnelAuthMode) -> Bool {
        switch authMode {
        case .password, .passwordAndTOTP:
            return true
        case .none, .totp, .kerberosAndTOTP:
            return false
        }
    }

    private static func usesKerberosAuth(_ authMode: TunnelAuthMode) -> Bool {
        switch authMode {
        case .kerberosAndTOTP:
            return true
        case .none, .password, .totp, .passwordAndTOTP:
            return false
        }
    }
}
