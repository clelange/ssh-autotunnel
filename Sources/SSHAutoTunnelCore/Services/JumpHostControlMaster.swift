import Foundation

public struct JumpHostControlMaster: Equatable, Sendable {
    public var profileID: UUID
    public var jumpHost: String
    public var controlPath: String
    public var readyPath: URL
    public var directory: URL
    public var command: SSHCommand
    public var finalProfile: TunnelProfile

    public init(
        profileID: UUID,
        jumpHost: String,
        controlPath: String,
        readyPath: URL,
        directory: URL,
        command: SSHCommand,
        finalProfile: TunnelProfile
    ) {
        self.profileID = profileID
        self.jumpHost = jumpHost
        self.controlPath = controlPath
        self.readyPath = readyPath
        self.directory = directory
        self.command = command
        self.finalProfile = finalProfile
    }
}

public enum JumpHostControlMasterFactory {
    public static func make(for profile: TunnelProfile, options: SSHLaunchOptions = .standard) throws -> JumpHostControlMaster {
        let jumpHost = try normalizedJumpHost(for: profile)
        let directory = controlDirectory(for: profile.id)
        let controlPath = directory.appendingPathComponent("control").path
        let readyPath = directory.appendingPathComponent("ready")

        var masterArguments = [
            "-M",
            "-tt",
            "-S", controlPath,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-p", "\(profile.sshPort)"
        ]

        if let strictHostKeyCheckingValue = profile.hostKeyPolicy.strictHostKeyCheckingValue {
            masterArguments += ["-o", "StrictHostKeyChecking=\(strictHostKeyCheckingValue)"]
        }

        if usesKeyboardInteractiveAuth(profile.authMode) {
            masterArguments += ["-o", "PreferredAuthentications=keyboard-interactive,password"]
        }

        if usesKerberosAuth(profile.authMode) {
            masterArguments += [
                "-o", "GSSAPIAuthentication=yes",
                "-o", "PreferredAuthentications=gssapi-with-mic,keyboard-interactive",
                "-o", "PasswordAuthentication=no"
            ]
        }

        SSHCommandBuilder.appendLaunchOptions(options, to: &masterArguments)
        masterArguments.append(jumpHost)

        return JumpHostControlMaster(
            profileID: profile.id,
            jumpHost: jumpHost,
            controlPath: controlPath,
            readyPath: readyPath,
            directory: directory,
            command: SSHCommand(arguments: masterArguments),
            finalProfile: Self.profile(profile, through: jumpHost, controlPath: controlPath)
        )
    }

    public static func profile(_ profile: TunnelProfile, through controlMaster: JumpHostControlMaster) -> TunnelProfile {
        self.profile(profile, through: controlMaster.jumpHost, controlPath: controlMaster.controlPath)
    }

    public static func controlDirectory(for profileID: UUID) -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ssh-autotunnel-\(profileID.uuidString)", isDirectory: true)
    }

    public static func requiresReadyMarker(for jumpHost: String) -> Bool {
        !readyPatterns(for: jumpHost).isEmpty
    }

    public static func readyPatterns(for jumpHost: String) -> [String] {
        guard jumpHost.localizedCaseInsensitiveContains("t3hop") else { return [] }
        return [
            "options (choose number):",
            "#?"
        ]
    }

    public static func hasJumpHost(_ profile: TunnelProfile) -> Bool {
        (try? normalizedJumpHost(for: profile)) != nil
    }

    private static func normalizedJumpHost(for profile: TunnelProfile) throws -> String {
        let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !jumpHost.isEmpty else {
            throw NSError(domain: "JumpHostControlMasterFactory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Jump host is not configured"])
        }
        return jumpHost
    }

    private static func profile(_ profile: TunnelProfile, through jumpHost: String, controlPath: String) -> TunnelProfile {
        var finalProfile = profile
        finalProfile.jumpHost = nil
        let proxyCommand = [
            "/usr/bin/ssh",
            "-o", "ControlMaster=auto",
            "-o", "BatchMode=yes",
            "-S", SSHCommand.shellQuoted(controlPath),
            "-W", "%h:%p",
            SSHCommand.shellQuoted(jumpHost)
        ].joined(separator: " ")
        finalProfile.extraSSHOptions += ["-o", "ProxyCommand=\(proxyCommand)"]
        return finalProfile
    }

    private static func usesKeyboardInteractiveAuth(_ authMode: TunnelAuthMode) -> Bool {
        switch authMode {
        case .password, .passwordAndTOTP:
            true
        case .none, .totp, .kerberosAndTOTP:
            false
        }
    }

    private static func usesKerberosAuth(_ authMode: TunnelAuthMode) -> Bool {
        switch authMode {
        case .kerberosAndTOTP:
            true
        case .none, .password, .totp, .passwordAndTOTP:
            false
        }
    }
}

final class JumpHostReadinessMarker {
    private let lock = NSLock()
    private let readyPath: URL
    private let patterns: [String]
    private var outputBuffer = Data()
    private var didMarkReady = false

    init?(controlMaster: JumpHostControlMaster) {
        let patterns = JumpHostControlMasterFactory.readyPatterns(for: controlMaster.jumpHost)
        guard !patterns.isEmpty else { return nil }
        readyPath = controlMaster.readyPath
        self.patterns = patterns
    }

    func handle(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !didMarkReady else { return }
        outputBuffer.append(data)
        if outputBuffer.count > 4096 {
            outputBuffer.removeFirst(outputBuffer.count - 2048)
        }
        guard let text = String(data: outputBuffer, encoding: .utf8)?.lowercased(),
              patterns.contains(where: { text.contains($0) }) else {
            return
        }
        didMarkReady = true
        FileManager.default.createFile(atPath: readyPath.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }
}
