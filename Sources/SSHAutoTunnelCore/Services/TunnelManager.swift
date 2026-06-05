import Foundation

public final class TunnelManager {
    public var onStatusChange: ((TunnelRuntimeStatus) -> Void)?
    public var onLog: ((UUID, String) -> Void)?
    public var onKeychainAccessCompleted: (() -> Void)?

    private let keychain: GenericPasswordReading
    private let processLauncher: SSHProcessLaunching
    private let socks5Probe: (Int) -> Bool
    private let socksPortAllocator: (Int, Set<Int>) throws -> RuntimeSocksPortAllocation
    private let reconnectDelay: (Int) -> TimeInterval
    private let totpGenerator: (String) throws -> String
    private let initialReadinessGracePeriod: TimeInterval
    private let processExitOutputSettleDelay: TimeInterval
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
        socksPortAllocator: @escaping (Int, Set<Int>) throws -> RuntimeSocksPortAllocation = {
            try RuntimeSocksPortAllocator.allocate(preferredPort: $0, reservedPorts: $1)
        },
        reconnectDelay: @escaping (Int) -> TimeInterval = { TunnelLifecyclePolicy.reconnectDelay(forAttempt: $0) },
        totpGenerator: @escaping (String) throws -> String = { try TOTPGenerator.generate(secretBase32: $0) },
        initialReadinessGracePeriod: TimeInterval = 60,
        processExitOutputSettleDelay: TimeInterval = 0.05,
        now: @escaping () -> Date = Date.init,
        startsHealthTimer: Bool = true
    ) {
        self.keychain = keychain
        self.processLauncher = processLauncher
        self.socks5Probe = socks5Probe
        self.socksPortAllocator = socksPortAllocator
        self.reconnectDelay = reconnectDelay
        self.totpGenerator = totpGenerator
        self.initialReadinessGracePeriod = initialReadinessGracePeriod
        self.processExitOutputSettleDelay = processExitOutputSettleDelay
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

    public func start(profile: TunnelProfile, options: SSHLaunchOptions = .standard, reservedSocksPorts: Set<Int> = []) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.startLocked(profile: profile, message: "Starting tunnel", options: options, reservedSocksPorts: reservedSocksPorts)
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

    @discardableResult
    public func stopAllWaiting(upTo timeout: TimeInterval, forceKillAfter: TimeInterval = 2.0) -> Bool {
        let managedTunnels = queue.sync {
            reconnectTokens.removeAll()
            reconnectAttempts.removeAll()
            let managedTunnels = Array(processes.values)
            for managed in managedTunnels {
                managed.stopReason = .user
                if managed.session.isRunning {
                    logEventLocked("termination requested; sending SIGTERM to pid \(managed.session.processIdentifier)", profileID: managed.profile.id)
                    managed.session.terminate()
                }
            }
            return managedTunnels
        }

        let sessions = managedTunnels.map { $0.session! }
        let didExit = SSHProcessStopper.waitForExit(
            sessions: sessions,
            timeout: timeout,
            forceKillAfter: forceKillAfter,
            onForceKill: { [weak self] session in
                guard let self else { return }
                let profileID = managedTunnels.first { $0.session.processIdentifier == session.processIdentifier }?.profile.id
                guard let profileID else { return }
                self.queue.async {
                    self.logEventLocked("still running after stop timeout; sending SIGKILL to pid \(session.processIdentifier)", profileID: profileID)
                }
            }
        )

        queue.sync {
            for managed in managedTunnels {
                flushRedactedOutputLocked(managed)
                if processes[managed.profile.id] === managed {
                    processes[managed.profile.id] = nil
                }
                if managed.session.isRunning {
                    updateStatusLocked(
                        managed.profile.id,
                        .failed,
                        "Could not stop SSH process before timeout",
                        pid: managed.session.processIdentifier
                    )
                } else {
                    updateStatusLocked(managed.profile.id, .stopped, "Stopped", pid: nil)
                }
            }
        }
        return didExit
    }

    public func reconnect(profile: TunnelProfile, options: SSHLaunchOptions = .standard, reservedSocksPorts: Set<Int> = []) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.stopLocked(profileID: profile.id, updateStatus: false, reason: .restart)
            self.scheduleReconnectLocked(profile: profile, message: "Reconnecting", delay: 1.0, options: options, reservedSocksPorts: reservedSocksPorts)
        }
    }

    private func startLocked(
        profile: TunnelProfile,
        message: String,
        options: SSHLaunchOptions,
        reservedSocksPorts: Set<Int>,
        excludedSocksPorts: Set<Int> = [],
        hasRetriedAppForwardingFailure: Bool = false
    ) {
        stopLocked(profileID: profile.id, updateStatus: false, reason: .replacement)
        updateStatusLocked(profile.id, .connecting, message, pid: nil)
        do {
            let runtimeProfile = try runtimeProfile(for: profile, reservedSocksPorts: reservedSocksPorts, excludedSocksPorts: excludedSocksPorts)
            if runtimeProfile.localSocksPort != profile.localSocksPort {
                logEventLocked(
                    "local SOCKS port \(profile.localSocksPort) unavailable; using \(runtimeProfile.localSocksPort) for this run",
                    profileID: profile.id
                )
            }
            let credentials = try credentials(for: profile)
            try runKerberosSwitchIfNeeded(profile: profile)
            let managed = try launch(
                profile: profile,
                runtimeProfile: runtimeProfile,
                credentials: credentials,
                options: options,
                reservedSocksPorts: reservedSocksPorts,
                excludedSocksPorts: excludedSocksPorts,
                hasRetriedAppForwardingFailure: hasRetriedAppForwardingFailure
            )
            processes[profile.id] = managed
            updateStatusLocked(
                profile.id,
                .connecting,
                "SSH process started",
                pid: managed.session.processIdentifier,
                effectiveLocalSocksPort: runtimeProfile.localSocksPort
            )
        } catch {
            updateStatusLocked(profile.id, .failed, error.localizedDescription, pid: nil)
        }
    }

    private func runtimeProfile(for profile: TunnelProfile, reservedSocksPorts: Set<Int>, excludedSocksPorts: Set<Int>) throws -> TunnelProfile {
        let reserved = reservedSocksPorts
            .union(excludedSocksPorts)
            .union(activeRuntimeSocksPorts(excluding: profile.id))
        let allocation = try socksPortAllocator(profile.localSocksPort, reserved)
        var runtimeProfile = profile
        runtimeProfile.localSocksPort = allocation.port
        return runtimeProfile
    }

    private func activeRuntimeSocksPorts(excluding profileID: UUID) -> Set<Int> {
        Set(processes.values.compactMap { managed in
            managed.profile.id == profileID ? nil : managed.runtimeProfile.localSocksPort
        })
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

    private func launch(
        profile: TunnelProfile,
        runtimeProfile: TunnelProfile,
        credentials: TunnelCredentials,
        options: SSHLaunchOptions,
        reservedSocksPorts: Set<Int>,
        excludedSocksPorts: Set<Int>,
        hasRetriedAppForwardingFailure: Bool
    ) throws -> ManagedTunnel {
        let command = SSHCommandBuilder.tunnelCommand(for: runtimeProfile, options: options)
        let managed = ManagedTunnel(
            profile: profile,
            runtimeProfile: runtimeProfile,
            credentials: credentials,
            launchOptions: options,
            reservedSocksPorts: reservedSocksPorts,
            excludedSocksPorts: excludedSocksPorts,
            hasRetriedAppForwardingFailure: hasRetriedAppForwardingFailure,
            startedAt: now()
        )
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
                    self.observeProcessTerminationLocked(managed, terminationStatus: session.terminationStatus)
                }
            }
        )
        return managed
    }

    private func handleOutput(_ data: Data, tunnel: ManagedTunnel) {
        tunnel.outputBuffer.append(data)
        let text = String(data: data, encoding: .utf8) ?? ""
        let redactedText = tunnel.redactor.redact(text)
        if !redactedText.isEmpty {
            onLog?(tunnel.profile.id, redactedText)
        }
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
            logEventLocked("host key prompt detected", profileID: tunnel.profile.id)
            switch tunnel.profile.hostKeyPolicy {
            case .promptAndAccept:
                tunnel.sentHostKeyConfirmation = true
                logEventLocked("host key prompt accepted", profileID: tunnel.profile.id)
                write("yes\n", to: tunnel)
            case .acceptNew, .strict:
                logEventLocked("host key prompt blocked by \(tunnel.profile.hostKeyPolicy.displayName) policy", profileID: tunnel.profile.id)
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
            logEventLocked("password prompt detected", profileID: tunnel.profile.id)
            if let password = tunnel.credentials.password {
                tunnel.sentPassword = true
                tunnel.addRedactedSecret(password)
                logEventLocked("password sent (<redacted>)", profileID: tunnel.profile.id)
                write(password + "\n", to: tunnel)
            } else {
                logEventLocked("password prompt detected but no password is configured", profileID: tunnel.profile.id)
            }
        case .sendTOTP:
            guard !tunnel.sentTOTP else { return }
            logEventLocked("TOTP prompt detected", profileID: tunnel.profile.id)
            if let totpReference = tunnel.credentials.totp {
                do {
                    let seed = try readGenericPassword(service: totpReference.service, account: totpReference.account)
                    let totp = try totpGenerator(seed)
                    tunnel.sentTOTP = true
                    tunnel.addRedactedSecret(totp)
                    logEventLocked("TOTP sent (<redacted>)", profileID: tunnel.profile.id)
                    write(totp + "\n", to: tunnel)
                } catch {
                    logEventLocked("TOTP generation failed: \(error.localizedDescription)", profileID: tunnel.profile.id)
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
        flushRedactedOutputLocked(managed)
        managed.stopReason = reason
        if managed.session.isRunning {
            logEventLocked("termination requested; sending SIGTERM to pid \(managed.session.processIdentifier)", profileID: profileID)
            managed.session.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self, weak managed] in
                guard let managed, managed.session.isRunning else { return }
                self?.queue.async {
                    self?.logEventLocked("still running after stop timeout; sending SIGKILL to pid \(managed.session.processIdentifier)", profileID: profileID)
                }
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
        options: SSHLaunchOptions,
        terminationStatus: Int32,
        exitDetail: String?,
        reservedSocksPorts: Set<Int>
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
                message: "\(sshExitMessage(status: terminationStatus, detail: exitDetail)); reconnecting",
                options: options,
                reservedSocksPorts: reservedSocksPorts
            )
        }
    }

    private func observeProcessTerminationLocked(_ managed: ManagedTunnel, terminationStatus: Int32) {
        guard processes[managed.profile.id] === managed else { return }
        guard managed.observedTerminationStatus == nil else { return }

        managed.observedTerminationStatus = terminationStatus
        flushRedactedOutputLocked(managed)

        let finalize = { [weak self, weak managed] in
            guard let self, let managed else { return }
            self.finalizeProcessTerminationLocked(managed)
        }

        if processExitOutputSettleDelay <= 0 {
            finalize()
        } else {
            queue.asyncAfter(deadline: .now() + processExitOutputSettleDelay, execute: finalize)
        }
    }

    private func finalizeProcessTerminationLocked(_ managed: ManagedTunnel) {
        guard processes[managed.profile.id] === managed,
              let terminationStatus = managed.observedTerminationStatus else {
            return
        }

        flushRedactedOutputLocked(managed)
        processes[managed.profile.id] = nil

        let forwardingFailure = managed.forwardingFailure
        if shouldRetryAppForwardingFailure(forwardingFailure, managed: managed) {
            let failedPort = managed.runtimeProfile.localSocksPort
            logEventLocked("local SOCKS port \(failedPort) became unavailable; retrying with alternate port", profileID: managed.profile.id)
            startLocked(
                profile: managed.profile,
                message: "Retrying tunnel with alternate SOCKS port",
                options: managed.launchOptions,
                reservedSocksPorts: managed.reservedSocksPorts,
                excludedSocksPorts: managed.excludedSocksPorts.union([failedPort]),
                hasRetriedAppForwardingFailure: true
            )
            return
        }

        let decision: TunnelLifecyclePolicy.ProcessExitDecision
        if forwardingFailure != nil, managed.stopReason == nil {
            decision = .markFailed
        } else {
            decision = TunnelLifecyclePolicy.processExitDecision(
                terminationStatus: terminationStatus,
                wasIntentionalStop: managed.stopReason != nil,
                autoReconnect: managed.profile.autoReconnect
            )
        }

        applyProcessExitDecisionLocked(
            decision,
            profile: managed.profile,
            options: managed.launchOptions,
            terminationStatus: terminationStatus,
            exitDetail: forwardingFailure?.statusDetail ?? managed.lastOutputLine,
            reservedSocksPorts: managed.reservedSocksPorts
        )
    }

    private func shouldRetryAppForwardingFailure(_ forwardingFailure: SSHForwardingFailure?, managed: ManagedTunnel) -> Bool {
        guard managed.stopReason == nil,
              !managed.hasRetriedAppForwardingFailure,
              forwardingFailure?.port == managed.runtimeProfile.localSocksPort else {
            return false
        }
        return true
    }

    private func sshExitMessage(status: Int32, detail: String?) -> String {
        guard let detail, !detail.isEmpty else {
            return "SSH exited with status \(status)"
        }
        return "SSH exited with status \(status): \(detail)"
    }

    private func scheduleReconnectLocked(
        profile: TunnelProfile,
        message: String,
        delay explicitDelay: TimeInterval? = nil,
        options: SSHLaunchOptions,
        reservedSocksPorts: Set<Int>
    ) {
        let attempt = (reconnectAttempts[profile.id] ?? 0) + 1
        reconnectAttempts[profile.id] = attempt
        let delay = explicitDelay ?? reconnectDelay(attempt)
        let token = UUID()
        reconnectTokens[profile.id] = token
        updateStatusLocked(profile.id, .reconnecting, message, pid: nil)
        logEventLocked("reconnect attempt \(attempt) scheduled in \(String(format: "%.1f", delay))s", profileID: profile.id)

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectTokens[profile.id] == token else { return }
            self.reconnectTokens[profile.id] = nil
            self.startLocked(profile: profile, message: "Reconnecting", options: options, reservedSocksPorts: reservedSocksPorts)
        }
    }

    private func updateStatusLocked(
        _ profileID: UUID,
        _ health: TunnelHealth,
        _ message: String,
        pid: Int32?,
        effectiveLocalSocksPort: Int? = nil
    ) {
        let previous = statuses[profileID]
        let status = TunnelRuntimeStatus(
            profileID: profileID,
            health: health,
            message: message,
            pid: pid,
            effectiveLocalSocksPort: effectiveLocalSocksPort
        )
        statuses[profileID] = status
        if previous?.health != health || previous?.message != message || previous?.pid != pid || previous?.effectiveLocalSocksPort != effectiveLocalSocksPort {
            var statusMessage = "status \(health.rawValue): \(message)"
            if let pid {
                statusMessage += " (pid \(pid))"
            }
            if let effectiveLocalSocksPort {
                statusMessage += " SOCKS 127.0.0.1:\(effectiveLocalSocksPort)"
            }
            logEventLocked(statusMessage, profileID: profileID)
        }
        DispatchQueue.main.async {
            self.onStatusChange?(status)
        }
    }

    private func logEventLocked(_ message: String, profileID: UUID) {
        onLog?(profileID, SSHTranscriptLog.event(kind: "tunnel", message: message, at: now()))
    }

    private func flushRedactedOutputLocked(_ managed: ManagedTunnel) {
        let text = managed.redactor.flush()
        if !text.isEmpty {
            onLog?(managed.profile.id, text)
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
            if managed.observedTerminationStatus != nil {
                continue
            }

            guard managed.session.isRunning else {
                observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
                continue
            }

            if socks5Probe(managed.runtimeProfile.localSocksPort) {
                let current = statuses[profileID]?.health
                if current != .healthy {
                    updateStatusLocked(
                        profileID,
                        .healthy,
                        "SOCKS5 handshake succeeded",
                        pid: managed.session.processIdentifier,
                        effectiveLocalSocksPort: managed.runtimeProfile.localSocksPort
                    )
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
                        pid: managed.session.processIdentifier,
                        effectiveLocalSocksPort: managed.runtimeProfile.localSocksPort
                    )
                case .markUnhealthy:
                    updateStatusLocked(
                        profileID,
                        .unhealthy,
                        "SOCKS5 probe failed",
                        pid: managed.session.processIdentifier,
                        effectiveLocalSocksPort: managed.runtimeProfile.localSocksPort
                    )
                case .reconnect:
                    stopLocked(profileID: profileID, updateStatus: false, reason: .restart)
                    scheduleReconnectLocked(
                        profile: managed.profile,
                        message: "SOCKS5 probe failed; reconnecting",
                        options: managed.launchOptions,
                        reservedSocksPorts: managed.reservedSocksPorts
                    )
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
    let runtimeProfile: TunnelProfile
    let credentials: TunnelCredentials
    let launchOptions: SSHLaunchOptions
    let reservedSocksPorts: Set<Int>
    let excludedSocksPorts: Set<Int>
    let hasRetriedAppForwardingFailure: Bool
    let startedAt: Date
    var session: SSHProcessSession!
    var outputBuffer = Data()
    var redactedSecrets: [String]
    var redactor: SSHTranscriptRedactor
    var stopReason: StopReason?
    var observedTerminationStatus: Int32?
    var sentHostKeyConfirmation = false
    var sentPassword = false
    var sentTOTP = false

    var forwardingFailure: SSHForwardingFailure? {
        guard let text = String(data: outputBuffer, encoding: .utf8) else {
            return nil
        }
        let redacted = SSHTranscriptLog.redact(text, secrets: redactedSecrets)
        return SSHForwardingFailureDetector.detect(in: redacted)
    }

    var lastOutputLine: String? {
        guard let text = String(data: outputBuffer, encoding: .utf8) else {
            return nil
        }
        let normalized = SSHTranscriptLog.redact(text, secrets: redactedSecrets).replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(240))
            }
        }
        return nil
    }

    init(
        profile: TunnelProfile,
        runtimeProfile: TunnelProfile,
        credentials: TunnelCredentials,
        launchOptions: SSHLaunchOptions,
        reservedSocksPorts: Set<Int>,
        excludedSocksPorts: Set<Int>,
        hasRetriedAppForwardingFailure: Bool,
        startedAt: Date
    ) {
        self.profile = profile
        self.runtimeProfile = runtimeProfile
        self.credentials = credentials
        self.launchOptions = launchOptions
        self.reservedSocksPorts = reservedSocksPorts
        self.excludedSocksPorts = excludedSocksPorts
        self.hasRetriedAppForwardingFailure = hasRetriedAppForwardingFailure
        self.startedAt = startedAt
        let initialSecrets = [credentials.password].compactMap(\.self)
        redactedSecrets = initialSecrets
        redactor = SSHTranscriptRedactor(secrets: initialSecrets)
    }

    func addRedactedSecret(_ secret: String) {
        redactedSecrets.append(secret)
        redactor.addSecret(secret)
    }
}
