import Foundation

public final class TunnelManager {
    public var onStatusChange: ((TunnelRuntimeStatus) -> Void)?
    public var onLog: ((UUID, String) -> Void)?
    public var onKeychainAccessCompleted: (() -> Void)?

    private let keychain: GenericPasswordReading
    private let processLauncher: SSHProcessLaunching
    private let socks5Probe: (Int) -> Bool
    private let reconnectDelay: (Int) -> TimeInterval
    private let totpGenerator: (String) throws -> String
    private let initialReadinessGracePeriod: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.clange.ssh-autotunnel.tunnels")
    private var processes: [UUID: ManagedTunnel] = [:]
    private var statuses: [UUID: TunnelRuntimeStatus] = [:]
    private var reconnectTokens: [UUID: UUID] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var healthTimer: DispatchSourceTimer?

    public convenience init(keychain: GenericPasswordReading = KeychainService()) {
        self.init(
            keychain: keychain,
            processLauncher: PTYSSHProcessLauncher(),
            socks5Probe: { SOCKS5Probe.probe(port: $0) },
            reconnectDelay: { TunnelLifecyclePolicy.reconnectDelay(forAttempt: $0) },
            totpGenerator: { try TOTPGenerator.generate(secretBase32: $0) },
            startsHealthTimer: true
        )
    }

    init(
        keychain: GenericPasswordReading = KeychainService(),
        processLauncher: SSHProcessLaunching,
        socks5Probe: @escaping (Int) -> Bool = { SOCKS5Probe.probe(port: $0) },
        reconnectDelay: @escaping (Int) -> TimeInterval = { TunnelLifecyclePolicy.reconnectDelay(forAttempt: $0) },
        totpGenerator: @escaping (String) throws -> String = { try TOTPGenerator.generate(secretBase32: $0) },
        initialReadinessGracePeriod: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        startsHealthTimer: Bool = true
    ) {
        self.keychain = keychain
        self.processLauncher = processLauncher
        self.socks5Probe = socks5Probe
        self.reconnectDelay = reconnectDelay
        self.totpGenerator = totpGenerator
        self.initialReadinessGracePeriod = initialReadinessGracePeriod
        self.now = now
        if startsHealthTimer {
            startHealthTimer()
        }
    }

    deinit {
        healthTimer?.cancel()
        reconnectTokens.removeAll()
        reconnectAttempts.removeAll()
        for managed in processes.values {
            managed.stopReason = .user
            if managed.session?.isRunning == true {
                managed.session.terminate()
                managed.session.forceKill()
            }
        }
        processes.removeAll()
    }

    public func status(for profileID: UUID) -> TunnelRuntimeStatus {
        queue.sync {
            statuses[profileID] ?? TunnelRuntimeStatus(profileID: profileID)
        }
    }

    public func allStatuses() -> [UUID: TunnelRuntimeStatus] {
        queue.sync { statuses }
    }

    public func start(profile: TunnelProfile) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.startLocked(profile: profile, message: "Starting tunnel")
        }
    }

    public func stop(profileID: UUID) {
        queue.async {
            self.reconnectTokens[profileID] = nil
            self.reconnectAttempts[profileID] = nil
            self.stopLocked(profileID: profileID, updateStatus: true, reason: .user)
        }
    }

    public func stopAll() {
        queue.sync {
            reconnectTokens.removeAll()
            reconnectAttempts.removeAll()
            for profileID in Array(processes.keys) {
                stopLocked(profileID: profileID, updateStatus: true, reason: .user)
            }
        }
    }

    public func reconnect(profile: TunnelProfile) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.stopLocked(profileID: profile.id, updateStatus: false, reason: .restart)
            self.scheduleReconnectLocked(profile: profile, message: "Reconnecting", delay: 1.0)
        }
    }

    private func startLocked(profile: TunnelProfile, message: String) {
        stopLocked(profileID: profile.id, updateStatus: false, reason: .replacement)
        updateStatusLocked(profile.id, .connecting, message, pid: nil)
        do {
            let credentials = try credentials(for: profile)
            try runKerberosSwitchIfNeeded(profile: profile)
            let managed = try launch(profile: profile, credentials: credentials)
            processes[profile.id] = managed
            updateStatusLocked(profile.id, .connecting, "SSH process started", pid: managed.session.processIdentifier)
        } catch {
            updateStatusLocked(profile.id, .failed, error.localizedDescription, pid: nil)
        }
    }

    private func credentials(for profile: TunnelProfile) throws -> TunnelCredentials {
        var password: String?
        var totp: KeychainSecretReference?

        if profile.authMode == .password || profile.authMode == .passwordAndTOTP {
            guard let service = profile.keychain.passwordService else {
                throw NSError(domain: "TunnelManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Password service is not configured"])
            }
            password = try readGenericPassword(service: service, account: profile.keychain.account)
        }

        if profile.authMode == .totp || profile.authMode == .passwordAndTOTP || profile.authMode == .kerberosAndTOTP {
            guard let service = profile.keychain.totpService else {
                throw NSError(domain: "TunnelManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "TOTP service is not configured"])
            }
            totp = KeychainSecretReference(service: service, account: profile.keychain.account)
        }

        return TunnelCredentials(password: password, totp: totp)
    }

    private func runKerberosSwitchIfNeeded(profile: TunnelProfile) throws {
        guard profile.authMode == .kerberosAndTOTP, FileManager.default.isExecutableFile(atPath: "/usr/bin/kswitch") else {
            return
        }
        let principal = "\(profile.user ?? profile.keychain.account)@CERN.CH"
        _ = try? ShellRunner.run("/usr/bin/kswitch", ["-p", principal])
    }

    private func launch(profile: TunnelProfile, credentials: TunnelCredentials) throws -> ManagedTunnel {
        let command = SSHCommandBuilder.tunnelCommand(for: profile)
        let managed = ManagedTunnel(profile: profile, credentials: credentials, startedAt: now())
        managed.session = try processLauncher.launch(
            command: command,
            onOutput: { [weak self, weak managed] data in
                guard let managed else { return }
                self?.queue.async {
                    self?.handleOutput(data, tunnel: managed)
                }
            },
            onTermination: { [weak self, weak managed] session in
                self?.queue.async {
                    guard let self, let managed else { return }
                    guard self.processes[profile.id] === managed else { return }
                    self.processes[profile.id] = nil

                    let decision = TunnelLifecyclePolicy.processExitDecision(
                        terminationStatus: session.terminationStatus,
                        wasIntentionalStop: managed.stopReason != nil,
                        autoReconnect: profile.autoReconnect
                    )
                    self.applyProcessExitDecisionLocked(
                        decision,
                        profile: profile,
                        terminationStatus: session.terminationStatus,
                        exitDetail: managed.lastOutputLine
                    )
                }
            }
        )
        return managed
    }

    private func handleOutput(_ data: Data, tunnel: ManagedTunnel) {
        tunnel.outputBuffer.append(data)
        let text = String(data: data, encoding: .utf8) ?? ""
        onLog?(tunnel.profile.id, text)
        respondIfNeeded(to: tunnel.outputBuffer, tunnel: tunnel)
        if tunnel.outputBuffer.count > 4096 {
            tunnel.outputBuffer.removeFirst(tunnel.outputBuffer.count - 2048)
        }
    }

    private func respondIfNeeded(to buffer: Data, tunnel: ManagedTunnel) {
        guard let text = String(data: buffer, encoding: .utf8),
              let action = SSHPromptResponder.nextAction(for: text) else {
            return
        }

        switch action {
        case .confirmHostKey:
            guard !tunnel.sentHostKeyConfirmation else { return }
            switch tunnel.profile.hostKeyPolicy {
            case .promptAndAccept:
                tunnel.sentHostKeyConfirmation = true
                write("yes\n", to: tunnel)
            case .acceptNew, .strict:
                updateStatusLocked(
                    tunnel.profile.id,
                    .failed,
                    "SSH host key prompt blocked by \(tunnel.profile.hostKeyPolicy.displayName) policy",
                    pid: tunnel.session.processIdentifier
                )
                stopLocked(profileID: tunnel.profile.id, updateStatus: false, reason: .user)
            }
        case .sendPassword:
            guard !tunnel.sentPassword else { return }
            if let password = tunnel.credentials.password {
                tunnel.sentPassword = true
                write(password + "\n", to: tunnel)
            }
        case .sendTOTP:
            guard !tunnel.sentTOTP else { return }
            if let totpReference = tunnel.credentials.totp {
                do {
                    let seed = try readGenericPassword(service: totpReference.service, account: totpReference.account)
                    let totp = try totpGenerator(seed)
                    tunnel.sentTOTP = true
                    write(totp + "\n", to: tunnel)
                } catch {
                    updateStatusLocked(
                        tunnel.profile.id,
                        .failed,
                        "Could not generate TOTP: \(error.localizedDescription)",
                        pid: tunnel.session.processIdentifier
                    )
                    stopLocked(profileID: tunnel.profile.id, updateStatus: false, reason: .user)
                }
            }
        }
    }

    private func readGenericPassword(service: String, account: String) throws -> String {
        defer {
            onKeychainAccessCompleted?()
        }
        return try keychain.readGenericPassword(service: service, account: account)
    }

    private func write(_ string: String, to tunnel: ManagedTunnel) {
        if let data = string.data(using: .utf8) {
            tunnel.session.write(data)
        }
    }

    private func stopLocked(profileID: UUID, updateStatus: Bool, reason: ManagedTunnel.StopReason) {
        guard let managed = processes.removeValue(forKey: profileID) else {
            if updateStatus {
                updateStatusLocked(profileID, .stopped, "Stopped", pid: nil)
            }
            return
        }
        managed.stopReason = reason
        if managed.session.isRunning {
            managed.session.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                managed.session.forceKill()
            }
        }
        if updateStatus {
            updateStatusLocked(profileID, .stopped, "Stopped", pid: nil)
        }
    }

    private func applyProcessExitDecisionLocked(
        _ decision: TunnelLifecyclePolicy.ProcessExitDecision,
        profile: TunnelProfile,
        terminationStatus: Int32,
        exitDetail: String?
    ) {
        switch decision {
        case .ignore:
            return
        case .markStopped:
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            updateStatusLocked(profile.id, .stopped, sshExitMessage(status: terminationStatus, detail: exitDetail), pid: nil)
        case .markFailed:
            reconnectTokens[profile.id] = nil
            updateStatusLocked(profile.id, .failed, sshExitMessage(status: terminationStatus, detail: exitDetail), pid: nil)
        case .reconnect:
            scheduleReconnectLocked(
                profile: profile,
                message: "\(sshExitMessage(status: terminationStatus, detail: exitDetail)); reconnecting"
            )
        }
    }

    private func sshExitMessage(status: Int32, detail: String?) -> String {
        guard let detail, !detail.isEmpty else {
            return "SSH exited with status \(status)"
        }
        return "SSH exited with status \(status): \(detail)"
    }

    private func scheduleReconnectLocked(profile: TunnelProfile, message: String, delay explicitDelay: TimeInterval? = nil) {
        let attempt = (reconnectAttempts[profile.id] ?? 0) + 1
        reconnectAttempts[profile.id] = attempt
        let delay = explicitDelay ?? reconnectDelay(attempt)
        let token = UUID()
        reconnectTokens[profile.id] = token
        updateStatusLocked(profile.id, .reconnecting, message, pid: nil)

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectTokens[profile.id] == token else { return }
            self.reconnectTokens[profile.id] = nil
            self.startLocked(profile: profile, message: "Reconnecting")
        }
    }

    private func updateStatusLocked(_ profileID: UUID, _ health: TunnelHealth, _ message: String, pid: Int32?) {
        let status = TunnelRuntimeStatus(profileID: profileID, health: health, message: message, pid: pid)
        statuses[profileID] = status
        DispatchQueue.main.async {
            self.onStatusChange?(status)
        }
    }

    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.checkHealthLocked()
        }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealthLocked() {
        for (profileID, managed) in Array(processes) {
            guard managed.session.isRunning else {
                processes[profileID] = nil
                let decision = TunnelLifecyclePolicy.processExitDecision(
                    terminationStatus: managed.session.terminationStatus,
                    wasIntentionalStop: managed.stopReason != nil,
                    autoReconnect: managed.profile.autoReconnect
                )
                applyProcessExitDecisionLocked(
                    decision,
                    profile: managed.profile,
                    terminationStatus: managed.session.terminationStatus,
                    exitDetail: managed.lastOutputLine
                )
                continue
            }

            if socks5Probe(managed.profile.localSocksPort) {
                let current = statuses[profileID]?.health
                if current != .healthy {
                    updateStatusLocked(profileID, .healthy, "SOCKS5 handshake succeeded", pid: managed.session.processIdentifier)
                }
                reconnectAttempts[profileID] = 0
            } else {
                let hasInitialReadinessGraceExpired = now().timeIntervalSince(managed.startedAt) >= initialReadinessGracePeriod
                let decision = TunnelLifecyclePolicy.healthProbeFailureDecision(
                    previousHealth: statuses[profileID]?.health,
                    autoReconnect: managed.profile.autoReconnect,
                    hasInitialReadinessGraceExpired: hasInitialReadinessGraceExpired
                )
                switch decision {
                case .waitForInitialReadiness:
                    updateStatusLocked(
                        profileID,
                        statuses[profileID]?.health == .reconnecting ? .reconnecting : .connecting,
                        "Waiting for SSH authentication and SOCKS5 listener",
                        pid: managed.session.processIdentifier
                    )
                case .markUnhealthy:
                    updateStatusLocked(profileID, .unhealthy, "SOCKS5 probe failed", pid: managed.session.processIdentifier)
                case .reconnect:
                    stopLocked(profileID: profileID, updateStatus: false, reason: .restart)
                    scheduleReconnectLocked(profile: managed.profile, message: "SOCKS5 probe failed; reconnecting")
                }
            }
        }
    }

    func runHealthCheckForTesting() {
        queue.sync {
            checkHealthLocked()
        }
    }
}

private struct TunnelCredentials {
    var password: String?
    var totp: KeychainSecretReference?
}

private struct KeychainSecretReference {
    var service: String
    var account: String
}

private final class ManagedTunnel {
    enum StopReason {
        case user
        case restart
        case replacement
    }

    let profile: TunnelProfile
    let credentials: TunnelCredentials
    let startedAt: Date
    var session: SSHProcessSession!
    var outputBuffer = Data()
    var stopReason: StopReason?
    var sentHostKeyConfirmation = false
    var sentPassword = false
    var sentTOTP = false

    var lastOutputLine: String? {
        guard let text = String(data: outputBuffer, encoding: .utf8) else {
            return nil
        }
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(240))
            }
        }
        return nil
    }

    init(profile: TunnelProfile, credentials: TunnelCredentials, startedAt: Date) {
        self.profile = profile
        self.credentials = credentials
        self.startedAt = startedAt
    }
}
