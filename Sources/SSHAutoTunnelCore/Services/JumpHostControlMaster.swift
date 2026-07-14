import Foundation

public struct JumpHostControlMaster: Equatable, Sendable {
    public var profileID: UUID
    public var jumpHost: String
    public var endpoint: HopEndpointKey
    public var signature: HopSessionSignature
    public var controlPath: String
    public var readyPath: URL
    public var manifestURL: URL
    public var lockURL: URL
    public var directory: URL
    public var command: SSHCommand
    public var finalProfile: TunnelProfile

    public init(
        profileID: UUID,
        jumpHost: String,
        endpoint: HopEndpointKey,
        signature: HopSessionSignature,
        controlPath: String,
        readyPath: URL,
        manifestURL: URL,
        lockURL: URL,
        directory: URL,
        command: SSHCommand,
        finalProfile: TunnelProfile
    ) {
        self.profileID = profileID
        self.jumpHost = jumpHost
        self.endpoint = endpoint
        self.signature = signature
        self.controlPath = controlPath
        self.readyPath = readyPath
        self.manifestURL = manifestURL
        self.lockURL = lockURL
        self.directory = directory
        self.command = command
        self.finalProfile = finalProfile
    }
}

public enum JumpHostControlMasterFactory {
    public static func make(
        for profile: TunnelProfile,
        options: SSHLaunchOptions = .standard,
        layout: HopControlPathLayout? = nil
    ) throws -> JumpHostControlMaster {
        let endpoint = try HopEndpointKey(profile: profile)
        let signature = HopSessionSignature(profile: profile, endpoint: endpoint)
        let paths = try (layout ?? HopControlPathLayout.default()).paths(for: endpoint)
        let jumpHost = endpoint.destination

        var masterArguments = [
            "-M",
            "-tt",
            "-S", paths.controlPath,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-p", "\(profile.sshPort)"
        ]
        SSHCommandBuilder.appendForwardingSuppression(to: &masterArguments)

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

        SSHCommandBuilder.appendLaunchOptions(options, profile: profile, to: &masterArguments)
        masterArguments.append(jumpHost)

        return JumpHostControlMaster(
            profileID: profile.id,
            jumpHost: jumpHost,
            endpoint: endpoint,
            signature: signature,
            controlPath: paths.controlPath,
            readyPath: paths.readyURL,
            manifestURL: paths.manifestURL,
            lockURL: paths.lockURL,
            directory: paths.directory,
            command: SSHCommand(arguments: masterArguments),
            finalProfile: Self.profile(profile, through: jumpHost, controlPath: paths.controlPath)
        )
    }

    public static func profile(_ profile: TunnelProfile, through controlMaster: JumpHostControlMaster) -> TunnelProfile {
        self.profile(profile, through: controlMaster.jumpHost, controlPath: controlMaster.controlPath)
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
        (try? HopEndpointKey(profile: profile)) != nil
    }

    private static func profile(_ profile: TunnelProfile, through jumpHost: String, controlPath: String) -> TunnelProfile {
        var finalProfile = profile
        finalProfile.jumpHost = nil
        let proxyCommand = [
            "/usr/bin/ssh",
            "-o", "ControlMaster=auto",
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
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
