import Darwin
import Foundation

public final class InteractiveSSHSessionRunner {
    private let keychain: GenericPasswordReading
    private let processLauncher: SSHProcessLaunching
    private let totpGenerator: (String) throws -> String
    private let runCommand: (String, [String]) throws -> Void
    private let runStatusCommand: (String, [String]) throws -> Int32

    public convenience init(keychain: GenericPasswordReading = KeychainService()) {
        self.init(
            keychain: keychain,
            processLauncher: PTYSSHProcessLauncher(),
            totpGenerator: { try TOTPGenerator.generate(secretBase32: $0) },
            runCommand: { executable, arguments in
                _ = try ShellRunner.run(executable, arguments)
            },
            runStatusCommand: { executable, arguments in
                try ShellRunner.run(executable, arguments).exitCode
            }
        )
    }

    init(
        keychain: GenericPasswordReading = KeychainService(),
        processLauncher: SSHProcessLaunching,
        totpGenerator: @escaping (String) throws -> String = { try TOTPGenerator.generate(secretBase32: $0) },
        runCommand: @escaping (String, [String]) throws -> Void = { executable, arguments in
            _ = try ShellRunner.run(executable, arguments)
        },
        runStatusCommand: @escaping (String, [String]) throws -> Int32 = { executable, arguments in
            try ShellRunner.run(executable, arguments).exitCode
        }
    ) {
        self.keychain = keychain
        self.processLauncher = processLauncher
        self.totpGenerator = totpGenerator
        self.runCommand = runCommand
        self.runStatusCommand = runStatusCommand
    }

    public func run(profile: TunnelProfile) throws -> Int32 {
        try run(profile: profile, input: .standardInput, output: .standardOutput, errorOutput: .standardError)
    }

    public func runJumpHostSession(profile: TunnelProfile) throws -> Int32 {
        try runJumpHostSession(profile: profile, input: .standardInput, output: .standardOutput, errorOutput: .standardError)
    }

    public func runFinalSessionThroughJumpHost(profile: TunnelProfile) throws -> Int32 {
        try runFinalSessionThroughJumpHost(profile: profile, input: .standardInput, output: .standardOutput, errorOutput: .standardError)
    }

    func run(
        profile: TunnelProfile,
        input: FileHandle,
        output: FileHandle,
        errorOutput: FileHandle,
        bridgeInput: Bool = true,
        configureTerminal: Bool = true
    ) throws -> Int32 {
        writeStatus("Preparing interactive SSH for \(profile.name)", to: output)
        try runKerberosSwitchIfNeeded(profile: profile)

        if InteractiveSSHJumpHostPolicy.requiresPersistentJumpHostSession(profile) {
            writeStatus(
                "This profile requires separate jump host and final SSH sessions. Use interactive-ssh-jump and interactive-ssh-final.",
                to: errorOutput
            )
            return 2
        }

        let credentials = try credentials(for: profile)
        return try runInteractiveSSH(
            profile: profile,
            credentials: credentials,
            input: input,
            output: output,
            errorOutput: errorOutput,
            bridgeInput: bridgeInput,
            configureTerminal: configureTerminal
        )
    }

    func runJumpHostSession(
        profile: TunnelProfile,
        input: FileHandle,
        output: FileHandle,
        errorOutput: FileHandle,
        bridgeInput: Bool = true,
        configureTerminal: Bool = true
    ) throws -> Int32 {
        writeStatus("Preparing jump host connection for \(profile.name)", to: output)
        let credentials = try credentials(for: profile)
        let controlMaster = try makeJumpHostControlMaster(profile: profile)
        try resetJumpHostControlMaster(controlMaster)
        writeStatus("Opening jump host setup connection to \(controlMaster.jumpHost)", to: output)
        writeStatus("Keep this window open while using the final SSH session.", to: output)
        writeStatus("Starting \(controlMaster.command.shellCommand)", to: output)
        let status = try runSession(
            command: controlMaster.command,
            profile: profile,
            credentials: credentials,
            input: input,
            output: output,
            errorOutput: errorOutput,
            bridgeInput: bridgeInput,
            configureTerminal: configureTerminal
        )
        try? FileManager.default.removeItem(at: controlMaster.directory)
        return status
    }

    func runFinalSessionThroughJumpHost(
        profile: TunnelProfile,
        input: FileHandle,
        output: FileHandle,
        errorOutput: FileHandle,
        bridgeInput: Bool = true,
        configureTerminal: Bool = true
    ) throws -> Int32 {
        writeStatus("Preparing final SSH session for \(profile.name)", to: output)
        let controlMaster = try makeJumpHostControlMaster(profile: profile)
        writeStatus("Waiting for authenticated jump host connection to \(controlMaster.jumpHost)", to: output)
        guard waitForJumpHostControlMaster(controlMaster) else {
            writeStatus("Timed out waiting for jump host connection. Keep the jump host window open and try again.", to: errorOutput)
            return 1
        }
        let credentials = try credentials(for: profile)
        return try runInteractiveSSH(
            profile: controlMaster.finalProfile,
            credentials: credentials,
            input: input,
            output: output,
            errorOutput: errorOutput,
            bridgeInput: bridgeInput,
            configureTerminal: configureTerminal
        )
    }

    private func runInteractiveSSH(
        profile: TunnelProfile,
        credentials: InteractiveSSHCredentials,
        input: FileHandle,
        output: FileHandle,
        errorOutput: FileHandle,
        bridgeInput: Bool,
        configureTerminal: Bool
    ) throws -> Int32 {
        let command = SSHCommandBuilder.interactiveCommand(for: profile)
        writeStatus("Starting \(command.shellCommand)", to: output)
        return try runSession(
            command: command,
            profile: profile,
            credentials: credentials,
            input: input,
            output: output,
            errorOutput: errorOutput,
            bridgeInput: bridgeInput,
            configureTerminal: configureTerminal
        )
    }

    private func runSession(
        command: SSHCommand,
        profile: TunnelProfile,
        credentials: InteractiveSSHCredentials,
        input: FileHandle,
        output: FileHandle,
        errorOutput: FileHandle,
        bridgeInput: Bool,
        configureTerminal: Bool
    ) throws -> Int32 {
        let promptState = InteractivePromptState(
            profile: profile,
            credentials: credentials,
            keychain: keychain,
            totpGenerator: totpGenerator,
            output: output,
            errorOutput: errorOutput
        )
        let sessionBox = SessionBox()
        let termination = DispatchSemaphore(value: 0)
        var terminationStatus: Int32 = 1

        let terminalMode = configureTerminal ? TerminalModeGuard(fileDescriptor: input.fileDescriptor) : nil
        defer {
            terminalMode?.restore()
        }

        let session = try processLauncher.launch(
            command: command,
            onOutput: { [promptState, sessionBox] data in
                promptState.handle(data, sessionBox: sessionBox)
            },
            onTermination: { session in
                terminationStatus = session.terminationStatus
                termination.signal()
            }
        )
        sessionBox.session = session
        promptState.respondToBufferedPrompt(sessionBox: sessionBox)

        if bridgeInput {
            DispatchQueue.global(qos: .userInitiated).async { [weak session] in
                while session?.isRunning == true {
                    let data = input.availableData
                    if data.isEmpty { break }
                    session?.write(data)
                }
            }
        }

        termination.wait()
        return terminationStatus
    }

    private func makeJumpHostControlMaster(profile: TunnelProfile) throws -> JumpHostControlMaster {
        let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !jumpHost.isEmpty else {
            throw NSError(domain: "InteractiveSSHSessionRunner", code: 4, userInfo: [NSLocalizedDescriptionKey: "Jump host is not configured"])
        }
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ssh-autotunnel-\(profile.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let controlPath = directory.appendingPathComponent("control").path

        var masterArguments = [
            "-M",
            "-tt",
            "-S", controlPath,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-p", "\(profile.sshPort)"
        ]
        if let strictHostKeyCheckingValue = profile.hostKeyPolicy.strictHostKeyCheckingValue {
            masterArguments += ["-o", "StrictHostKeyChecking=\(strictHostKeyCheckingValue)"]
        }
        masterArguments += ["-o", "PreferredAuthentications=keyboard-interactive"]
        masterArguments.append(jumpHost)

        var finalProfile = profile
        finalProfile.jumpHost = nil
        let proxyCommand = [
            "/usr/bin/ssh",
            "-S", SSHCommand.shellQuoted(controlPath),
            "-W", "%h:%p",
            SSHCommand.shellQuoted(jumpHost)
        ].joined(separator: " ")
        finalProfile.extraSSHOptions += ["-o", "ProxyCommand=\(proxyCommand)"]

        return JumpHostControlMaster(
            jumpHost: jumpHost,
            controlPath: controlPath,
            directory: directory,
            command: SSHCommand(arguments: masterArguments),
            finalProfile: finalProfile
        )
    }

    private func resetJumpHostControlMaster(_ controlMaster: JumpHostControlMaster) throws {
        try? runCommand("/usr/bin/ssh", ["-S", controlMaster.controlPath, "-O", "exit", controlMaster.jumpHost])
        try? FileManager.default.removeItem(at: controlMaster.directory)
        try FileManager.default.createDirectory(at: controlMaster.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlMaster.directory.path)
    }

    private func waitForJumpHostControlMaster(_ controlMaster: JumpHostControlMaster, timeoutSeconds: TimeInterval = 120) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if (try? runStatusCommand("/usr/bin/ssh", ["-S", controlMaster.controlPath, "-O", "check", controlMaster.jumpHost])) == 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func writeStatus(_ message: String, to output: FileHandle) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        output.write(data)
    }

    private func credentials(for profile: TunnelProfile) throws -> InteractiveSSHCredentials {
        var password: String?
        var totp: KeychainSecretReference?

        if profile.authMode == .password || profile.authMode == .passwordAndTOTP {
            guard let service = profile.keychain.passwordService else {
                throw NSError(domain: "InteractiveSSHSessionRunner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Password service is not configured"])
            }
            password = try keychain.readGenericPassword(service: service, account: profile.keychain.account)
        }

        if profile.authMode == .totp || profile.authMode == .passwordAndTOTP || profile.authMode == .kerberosAndTOTP {
            guard let service = profile.keychain.totpService else {
                throw NSError(domain: "InteractiveSSHSessionRunner", code: 3, userInfo: [NSLocalizedDescriptionKey: "TOTP service is not configured"])
            }
            totp = KeychainSecretReference(service: service, account: profile.keychain.account)
        }

        return InteractiveSSHCredentials(password: password, totp: totp)
    }

    private func runKerberosSwitchIfNeeded(profile: TunnelProfile) throws {
        guard profile.authMode == .kerberosAndTOTP, FileManager.default.isExecutableFile(atPath: "/usr/bin/kswitch") else {
            return
        }
        let principal = "\(profile.user ?? profile.keychain.account)@CERN.CH"
        try runCommand("/usr/bin/kswitch", ["-p", principal])
    }
}

private struct JumpHostControlMaster {
    var jumpHost: String
    var controlPath: String
    var directory: URL
    var command: SSHCommand
    var finalProfile: TunnelProfile
}

private struct InteractiveSSHCredentials {
    var password: String?
    var totp: KeychainSecretReference?
}

private struct KeychainSecretReference {
    var service: String
    var account: String
}

private final class InteractivePromptState {
    private let lock = NSLock()
    private let profile: TunnelProfile
    private let credentials: InteractiveSSHCredentials
    private let keychain: GenericPasswordReading
    private let totpGenerator: (String) throws -> String
    private let output: FileHandle
    private let errorOutput: FileHandle
    private var outputBuffer = Data()
    private var sentHostKeyConfirmation = false
    private var sentPassword = false
    private var sentTOTP = false

    init(
        profile: TunnelProfile,
        credentials: InteractiveSSHCredentials,
        keychain: GenericPasswordReading,
        totpGenerator: @escaping (String) throws -> String,
        output: FileHandle,
        errorOutput: FileHandle
    ) {
        self.profile = profile
        self.credentials = credentials
        self.keychain = keychain
        self.totpGenerator = totpGenerator
        self.output = output
        self.errorOutput = errorOutput
    }

    func handle(_ data: Data, sessionBox: SessionBox) {
        output.write(data)

        lock.lock()
        defer { lock.unlock() }

        outputBuffer.append(data)
        respondIfNeeded(sessionBox: sessionBox)
        if outputBuffer.count > 4096 {
            outputBuffer.removeFirst(outputBuffer.count - 2048)
        }
    }

    func respondToBufferedPrompt(sessionBox: SessionBox) {
        lock.lock()
        defer { lock.unlock() }
        respondIfNeeded(sessionBox: sessionBox)
    }

    private func respondIfNeeded(sessionBox: SessionBox) {
        guard let text = String(data: outputBuffer, encoding: .utf8),
              let action = SSHPromptResponder.nextAction(for: text) else {
            return
        }

        switch action {
        case .confirmHostKey:
            guard !sentHostKeyConfirmation else { return }
            guard profile.hostKeyPolicy == .promptAndAccept else { return }
            guard sessionBox.session != nil else { return }
            sentHostKeyConfirmation = true
            write("yes\n", sessionBox: sessionBox)
        case .sendPassword:
            guard !sentPassword, let password = credentials.password else { return }
            guard sessionBox.session != nil else { return }
            sentPassword = true
            write(password + "\n", sessionBox: sessionBox)
        case .sendTOTP:
            guard !sentTOTP, let totpReference = credentials.totp else { return }
            guard sessionBox.session != nil else { return }
            do {
                let seed = try keychain.readGenericPassword(service: totpReference.service, account: totpReference.account)
                let totp = try totpGenerator(seed)
                sentTOTP = true
                write(totp + "\n", sessionBox: sessionBox)
            } catch {
                let message = "\nCould not generate TOTP: \(error.localizedDescription)\n"
                if let data = message.data(using: .utf8) {
                    errorOutput.write(data)
                }
            }
        }
    }

    private func write(_ string: String, sessionBox: SessionBox) {
        guard let data = string.data(using: .utf8) else { return }
        sessionBox.session?.write(data)
    }
}

private final class SessionBox {
    var session: SSHProcessSession?
}

private final class TerminalModeGuard {
    private let fileDescriptor: Int32
    private var original: termios
    private var restored = false

    init?(fileDescriptor: Int32) {
        guard isatty(fileDescriptor) == 1 else { return nil }
        var current = termios()
        guard tcgetattr(fileDescriptor, &current) == 0 else { return nil }
        original = current
        self.fileDescriptor = fileDescriptor

        var raw = current
        cfmakeraw(&raw)
        guard tcsetattr(fileDescriptor, TCSANOW, &raw) == 0 else { return nil }
    }

    deinit {
        restore()
    }

    func restore() {
        guard !restored else { return }
        restored = true
        tcsetattr(fileDescriptor, TCSANOW, &original)
    }
}
