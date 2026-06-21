import Foundation

public final class HopConnectionManager {
    public var onStatusChange: ((HopRuntimeStatus) -> Void)?
    public var onLog: ((UUID, String) -> Void)?
    public var onKeychainAccessCompleted: (() -> Void)?

    private let keychain: GenericPasswordReading
    private let processLauncher: SSHProcessLaunching
    private let healthCheck: (JumpHostControlMaster) -> Bool
    private let reconnectDelay: (Int) -> TimeInterval
    private let totpGenerator: (String) throws -> String
    private let initialReadinessGracePeriod: TimeInterval
    private let processExitObservationDelay: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.clange.ssh-autotunnel.hops")
    private var processes: [UUID: ManagedHopConnection] = [:]
    private var statuses: [UUID: HopRuntimeStatus] = [:]
    private var reconnectTokens: [UUID: UUID] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var healthTimer: DispatchSourceTimer?

    public convenience init(keychain: GenericPasswordReading = KeychainService()) {
        self.init(
            keychain: keychain,
            processLauncher: PTYSSHProcessLauncher(),
            healthCheck: { controlMaster in
                (try? ShellRunner.run("/usr/bin/ssh", ["-S", controlMaster.controlPath, "-O", "check", controlMaster.jumpHost]).exitCode) == 0
            },
            reconnectDelay: { TunnelLifecyclePolicy.reconnectDelay(forAttempt: $0) },
            totpGenerator: { try TOTPGenerator.generate(secretBase32: $0) },
            startsHealthTimer: true
        )
    }

    init(
        keychain: GenericPasswordReading = KeychainService(),
        processLauncher: SSHProcessLaunching,
        healthCheck: @escaping (JumpHostControlMaster) -> Bool,
        reconnectDelay: @escaping (Int) -> TimeInterval = { TunnelLifecyclePolicy.reconnectDelay(forAttempt: $0) },
        totpGenerator: @escaping (String) throws -> String = { try TOTPGenerator.generate(secretBase32: $0) },
        initialReadinessGracePeriod: TimeInterval = 60,
        processExitObservationDelay: TimeInterval = 0.1,
        now: @escaping () -> Date = Date.init,
        startsHealthTimer: Bool = true
    ) {
        self.keychain = keychain
        self.processLauncher = processLauncher
        self.healthCheck = healthCheck
        self.reconnectDelay = reconnectDelay
        self.totpGenerator = totpGenerator
        self.initialReadinessGracePeriod = initialReadinessGracePeriod
        self.processExitObservationDelay = processExitObservationDelay
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

    public func status(for profileID: UUID) -> HopRuntimeStatus? {
        queue.sync {
            statuses[profileID]
        }
    }

    public func allStatuses() -> [UUID: HopRuntimeStatus] {
        queue.sync { statuses }
    }

    public func controlMaster(for profileID: UUID) -> JumpHostControlMaster? {
        queue.sync {
            guard statuses[profileID]?.health == .healthy else { return nil }
            return processes[profileID]?.controlMaster
        }
    }

    public func start(profile: TunnelProfile, options: SSHLaunchOptions = .standard) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.startLocked(profile: profile, message: "Starting hop connection", options: options)
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
        let managedHops = queue.sync {
            reconnectTokens.removeAll()
            reconnectAttempts.removeAll()
            let managedHops = Array(processes.values)
            for managed in managedHops {
                managed.stopReason = .user
                if managed.session.isRunning {
                    logEventLocked("termination requested; sending SIGTERM to pid \(managed.session.processIdentifier)", profileID: managed.profile.id)
                    managed.session.terminate()
                }
            }
            return managedHops
        }

        let sessions = managedHops.map { $0.session! }
        let didExit = SSHProcessStopper.waitForExit(
            sessions: sessions,
            timeout: timeout,
            forceKillAfter: forceKillAfter,
            onForceKill: { [weak self] session in
                guard let self else { return }
                let profileID = managedHops.first { $0.session.processIdentifier == session.processIdentifier }?.profile.id
                guard let profileID else { return }
                self.queue.async {
                    self.logEventLocked("still running after stop timeout; sending SIGKILL to pid \(session.processIdentifier)", profileID: profileID)
                }
            }
        )

        queue.sync {
            for managed in managedHops {
                flushRedactedOutputLocked(managed)
                if processes[managed.profile.id] === managed {
                    processes[managed.profile.id] = nil
                }
                try? FileManager.default.removeItem(at: managed.controlMaster.directory)
                if managed.session.isRunning {
                    updateStatusLocked(
                        managed.profile.id,
                        jumpHost: managed.controlMaster.jumpHost,
                        .failed,
                        "Could not stop SSH hop process before timeout",
                        pid: managed.session.processIdentifier
                    )
                } else {
                    updateStatusLocked(managed.profile.id, jumpHost: managed.controlMaster.jumpHost, .stopped, "Stopped", pid: nil)
                }
            }
        }
        return didExit
    }

    public func reconnect(profile: TunnelProfile, options: SSHLaunchOptions = .standard) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.stopLocked(profileID: profile.id, updateStatus: false, reason: .restart)
            self.scheduleReconnectLocked(profile: profile, message: "Reconnecting hop", delay: 1.0, options: options)
        }
    }

    private func startLocked(profile: TunnelProfile, message: String, options: SSHLaunchOptions) {
        stopLocked(profileID: profile.id, updateStatus: false, reason: .replacement)
        do {
            let controlMaster = try JumpHostControlMasterFactory.make(for: profile, options: options)
            updateStatusLocked(profile.id, jumpHost: controlMaster.jumpHost, .connecting, message, pid: nil)
            try resetControlMaster(controlMaster)
            let credentials = try credentials(for: profile)
            try runKerberosSwitchIfNeeded(profile: profile)
            let managed = try launch(profile: profile, controlMaster: controlMaster, credentials: credentials, options: options)
            processes[profile.id] = managed
            updateStatusLocked(profile.id, jumpHost: controlMaster.jumpHost, .connecting, "SSH hop process started", pid: managed.session.processIdentifier)
        } catch {
            let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            updateStatusLocked(profile.id, jumpHost: jumpHost, .failed, error.localizedDescription, pid: nil)
        }
    }

    private func credentials(for profile: TunnelProfile) throws -> HopCredentials {
        var password: String?
        var totp: HopSecretReference?

        if profile.authMode == .password || profile.authMode == .passwordAndTOTP {
            guard let service = profile.keychain.passwordService else {
                throw NSError(domain: "HopConnectionManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Password service is not configured"])
            }
            password = try readGenericPassword(service: service, account: profile.keychain.account)
        }

        if profile.authMode == .totp || profile.authMode == .passwordAndTOTP || profile.authMode == .kerberosAndTOTP {
            guard let service = profile.keychain.totpService else {
                throw NSError(domain: "HopConnectionManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "TOTP service is not configured"])
            }
            totp = HopSecretReference(service: service, account: profile.keychain.account)
        }

        return HopCredentials(password: password, totp: totp)
    }

    private func runKerberosSwitchIfNeeded(profile: TunnelProfile) throws {
        guard profile.authMode == .kerberosAndTOTP, FileManager.default.isExecutableFile(atPath: "/usr/bin/kswitch") else {
            return
        }
        let principal = "\(profile.user ?? profile.keychain.account)@CERN.CH"
        _ = try? ShellRunner.run("/usr/bin/kswitch", ["-p", principal])
    }

    private func resetControlMaster(_ controlMaster: JumpHostControlMaster) throws {
        if FileManager.default.fileExists(atPath: controlMaster.controlPath) {
            _ = try? ShellRunner.run("/usr/bin/ssh", ["-S", controlMaster.controlPath, "-O", "exit", controlMaster.jumpHost])
        }
        try? FileManager.default.removeItem(at: controlMaster.directory)
        try FileManager.default.createDirectory(at: controlMaster.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlMaster.directory.path)
    }

    private func launch(profile: TunnelProfile, controlMaster: JumpHostControlMaster, credentials: HopCredentials, options: SSHLaunchOptions) throws -> ManagedHopConnection {
        let managed = ManagedHopConnection(profile: profile, controlMaster: controlMaster, credentials: credentials, launchOptions: options, startedAt: now())
        managed.session = try processLauncher.launch(
            command: controlMaster.command,
            onOutput: { [weak self, weak managed] data in
                guard let managed else { return }
                self?.queue.async {
                    self?.handleOutput(data, hop: managed)
                }
            },
            onTermination: { [weak self, weak managed] session in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + self.processExitObservationDelay) { [weak self, weak managed] in
                    guard let self, let managed else { return }
                    guard self.processes[profile.id] === managed else { return }
                    self.flushRedactedOutputLocked(managed)
                    self.processes[profile.id] = nil

                    let hasExistingSessionConflict = managed.hasExistingSessionConflict || managed.matchesExistingSessionConflict
                    let decision = hasExistingSessionConflict
                        ? TunnelLifecyclePolicy.ProcessExitDecision.markFailed
                        : TunnelLifecyclePolicy.processExitDecision(
                        terminationStatus: session.terminationStatus,
                        wasIntentionalStop: managed.stopReason != nil,
                        autoReconnect: profile.autoReconnect
                    )
                    self.applyProcessExitDecisionLocked(
                        decision,
                        profile: profile,
                        controlMaster: controlMaster,
                        options: managed.launchOptions,
                        terminationStatus: session.terminationStatus,
                        exitDetail: managed.lastOutputLine,
                        forcedFailureMessage: hasExistingSessionConflict
                        ? Self.existingSessionFailureMessage(for: controlMaster.jumpHost)
                        : nil
                    )
                }
            }
        )
        return managed
    }

    private func handleOutput(_ data: Data, hop: ManagedHopConnection) {
        hop.outputBuffer.append(data)
        let text = String(data: data, encoding: .utf8) ?? ""
        let redactedText = hop.redactor.redact(text)
        if !redactedText.isEmpty {
            onLog?(hop.profile.id, redactedText)
        }
        hop.readinessMarker?.handle(data)
        detectExistingSessionConflict(in: hop)
        respondIfNeeded(to: hop.outputBuffer, hop: hop)
        if hop.outputBuffer.count > 4096 {
            hop.outputBuffer.removeFirst(hop.outputBuffer.count - 2048)
        }
    }

    private func detectExistingSessionConflict(in hop: ManagedHopConnection) {
        guard !hop.hasExistingSessionConflict else { return }
        guard let transcriptText = String(data: hop.outputBuffer, encoding: .utf8)?.lowercased() else { return }
        if Self.matchesExistingSessionMessage(in: transcriptText) {
            hop.hasExistingSessionConflict = true
            reconnectTokens[hop.profile.id] = nil
            reconnectAttempts[hop.profile.id] = nil
            logEventLocked("existing hop session detected; stopping auto-reconnect", profileID: hop.profile.id)
            let failureMessage = Self.existingSessionFailureMessage(for: hop.controlMaster.jumpHost)
            updateStatusLocked(
                hop.profile.id,
                jumpHost: hop.controlMaster.jumpHost,
                .failed,
                failureMessage,
                pid: hop.session.processIdentifier
            )
            stopLocked(profileID: hop.profile.id, updateStatus: false, reason: .user)
            return
        }
    }

    private static func existingSessionFailureMessage(for jumpHost: String) -> String {
        "SSH hop failed: an existing hop session is already active on \(jumpHost). Close that session and retry. Auto-reconnect was stopped for this attempt."
    }

    fileprivate static func matchesExistingSessionMessage(in text: String) -> Bool {
        let normalizedText = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalizedText.contains("you already have an existing session")
            || normalizedText.contains("multiple sessions to this systems for the same user are not possible")
    }

    private func respondIfNeeded(to buffer: Data, hop: ManagedHopConnection) {
        guard let text = String(data: buffer, encoding: .utf8),
              let action = SSHPromptResponder.nextAction(for: text) else {
            return
        }

        switch action {
        case .confirmHostKey:
            guard !hop.sentHostKeyConfirmation else { return }
            logEventLocked("host key prompt detected", profileID: hop.profile.id)
            switch hop.profile.hostKeyPolicy {
            case .promptAndAccept:
                hop.sentHostKeyConfirmation = true
                logEventLocked("host key prompt accepted", profileID: hop.profile.id)
                write("yes\n", to: hop)
            case .acceptNew, .strict:
                logEventLocked("host key prompt blocked by \(hop.profile.hostKeyPolicy.displayName) policy", profileID: hop.profile.id)
                updateStatusLocked(
                    hop.profile.id,
                    jumpHost: hop.controlMaster.jumpHost,
                    .failed,
                    "SSH host key prompt blocked by \(hop.profile.hostKeyPolicy.displayName) policy",
                    pid: hop.session.processIdentifier
                )
                stopLocked(profileID: hop.profile.id, updateStatus: false, reason: .user)
            }
        case .sendPassword:
            guard !hop.sentPassword else { return }
            logEventLocked("password prompt detected", profileID: hop.profile.id)
            if let password = hop.credentials.password {
                hop.sentPassword = true
                hop.addRedactedSecret(password)
                logEventLocked("password sent (<redacted>)", profileID: hop.profile.id)
                write(password + "\n", to: hop)
            } else {
                logEventLocked("password prompt detected but no password is configured", profileID: hop.profile.id)
            }
        case .sendTOTP:
            guard !hop.sentTOTP else { return }
            logEventLocked("TOTP prompt detected", profileID: hop.profile.id)
            if let totpReference = hop.credentials.totp {
                do {
                    let seed = try readGenericPassword(service: totpReference.service, account: totpReference.account)
                    let totp = try totpGenerator(seed)
                    hop.sentTOTP = true
                    hop.addRedactedSecret(totp)
                    logEventLocked("TOTP sent (<redacted>)", profileID: hop.profile.id)
                    write(totp + "\n", to: hop)
                } catch {
                    logEventLocked("TOTP generation failed: \(error.localizedDescription)", profileID: hop.profile.id)
                    updateStatusLocked(
                        hop.profile.id,
                        jumpHost: hop.controlMaster.jumpHost,
                        .failed,
                        "Could not generate TOTP: \(error.localizedDescription)",
                        pid: hop.session.processIdentifier
                    )
                    stopLocked(profileID: hop.profile.id, updateStatus: false, reason: .user)
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

    private func write(_ string: String, to hop: ManagedHopConnection) {
        if let data = string.data(using: .utf8) {
            hop.session.write(data)
        }
    }

    private func stopLocked(profileID: UUID, updateStatus: Bool, reason: ManagedHopConnection.StopReason) {
        guard let managed = processes.removeValue(forKey: profileID) else {
            if updateStatus {
                let existing = statuses[profileID]
                updateStatusLocked(profileID, jumpHost: existing?.jumpHost ?? "", .stopped, "Stopped", pid: nil)
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
        try? FileManager.default.removeItem(at: managed.controlMaster.directory)
        if updateStatus {
            updateStatusLocked(profileID, jumpHost: managed.controlMaster.jumpHost, .stopped, "Stopped", pid: nil)
        }
    }

    private func applyProcessExitDecisionLocked(
        _ decision: TunnelLifecyclePolicy.ProcessExitDecision,
        profile: TunnelProfile,
        controlMaster: JumpHostControlMaster,
        options: SSHLaunchOptions,
        terminationStatus: Int32,
        exitDetail: String?,
        forcedFailureMessage: String? = nil
    ) {
        switch decision {
        case .ignore:
            return
        case .markStopped:
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            updateStatusLocked(profile.id, jumpHost: controlMaster.jumpHost, .stopped, sshExitMessage(status: terminationStatus, detail: exitDetail), pid: nil)
        case .markFailed:
            reconnectTokens[profile.id] = nil
            updateStatusLocked(
                profile.id,
                jumpHost: controlMaster.jumpHost,
                .failed,
                forcedFailureMessage ?? sshExitMessage(status: terminationStatus, detail: exitDetail),
                pid: nil
            )
        case .reconnect:
            scheduleReconnectLocked(
                profile: profile,
                message: "\(sshExitMessage(status: terminationStatus, detail: exitDetail)); reconnecting hop",
                options: options
            )
        }
    }

    private func sshExitMessage(status: Int32, detail: String?) -> String {
        guard let detail, !detail.isEmpty else {
            return "SSH hop exited with status \(status)"
        }
        return "SSH hop exited with status \(status): \(detail)"
    }

    private func scheduleReconnectLocked(profile: TunnelProfile, message: String, delay explicitDelay: TimeInterval? = nil, options: SSHLaunchOptions) {
        let attempt = (reconnectAttempts[profile.id] ?? 0) + 1
        if let limit = profile.curatedSSHOptions.maxReconnectAttempts, attempt > limit {
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? statuses[profile.id]?.jumpHost ?? ""
            updateStatusLocked(profile.id, jumpHost: jumpHost, .failed, "Hop reconnect attempt limit reached after \(limit) attempts", pid: nil)
            logEventLocked("reconnect attempt limit \(limit) reached; stopping hop auto-reconnect", profileID: profile.id)
            return
        }
        reconnectAttempts[profile.id] = attempt
        let delay = explicitDelay ?? reconnectDelay(attempt)
        let token = UUID()
        reconnectTokens[profile.id] = token
        let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? statuses[profile.id]?.jumpHost ?? ""
        updateStatusLocked(profile.id, jumpHost: jumpHost, .reconnecting, message, pid: nil)
        logEventLocked("reconnect attempt \(attempt) scheduled in \(String(format: "%.1f", delay))s", profileID: profile.id)

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectTokens[profile.id] == token else { return }
            self.reconnectTokens[profile.id] = nil
            self.startLocked(profile: profile, message: "Reconnecting hop", options: options)
        }
    }

    private func updateStatusLocked(_ profileID: UUID, jumpHost: String, _ health: TunnelHealth, _ message: String, pid: Int32?) {
        let previous = statuses[profileID]
        let status = HopRuntimeStatus(profileID: profileID, jumpHost: jumpHost, health: health, message: message, pid: pid)
        statuses[profileID] = status
        if previous?.jumpHost != jumpHost || previous?.health != health || previous?.message != message || previous?.pid != pid {
            var statusMessage = "status \(health.rawValue): \(message)"
            if !jumpHost.isEmpty {
                statusMessage += " via \(jumpHost)"
            }
            if let pid {
                statusMessage += " (pid \(pid))"
            }
            logEventLocked(statusMessage, profileID: profileID)
        }
        DispatchQueue.main.async {
            self.onStatusChange?(status)
        }
    }

    private func logEventLocked(_ message: String, profileID: UUID) {
        onLog?(profileID, SSHTranscriptLog.event(kind: "hop", message: message, at: now()))
    }

    private func flushRedactedOutputLocked(_ managed: ManagedHopConnection) {
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
            guard managed.session.isRunning else {
                flushRedactedOutputLocked(managed)
                processes[profileID] = nil
                let decision = TunnelLifecyclePolicy.processExitDecision(
                    terminationStatus: managed.session.terminationStatus,
                    wasIntentionalStop: managed.stopReason != nil,
                    autoReconnect: managed.profile.autoReconnect
                )
                applyProcessExitDecisionLocked(
                    decision,
                    profile: managed.profile,
                    controlMaster: managed.controlMaster,
                    options: managed.launchOptions,
                    terminationStatus: managed.session.terminationStatus,
                    exitDetail: managed.lastOutputLine
                )
                continue
            }

            if healthCheck(managed.controlMaster), isReady(managed.controlMaster) {
                let current = statuses[profileID]?.health
                if current != .healthy {
                    updateStatusLocked(profileID, jumpHost: managed.controlMaster.jumpHost, .healthy, "Jump host ControlMaster is ready", pid: managed.session.processIdentifier)
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
                    let message = JumpHostControlMasterFactory.requiresReadyMarker(for: managed.controlMaster.jumpHost)
                        ? "Waiting for SSH authentication and jump host setup prompt"
                        : "Waiting for SSH authentication and ControlMaster"
                    updateStatusLocked(
                        profileID,
                        jumpHost: managed.controlMaster.jumpHost,
                        statuses[profileID]?.health == .reconnecting ? .reconnecting : .connecting,
                        message,
                        pid: managed.session.processIdentifier
                    )
                case .markUnhealthy:
                    updateStatusLocked(profileID, jumpHost: managed.controlMaster.jumpHost, .unhealthy, "Jump host ControlMaster check failed", pid: managed.session.processIdentifier)
                case .reconnect:
                    stopLocked(profileID: profileID, updateStatus: false, reason: .restart)
                    scheduleReconnectLocked(profile: managed.profile, message: "Jump host ControlMaster check failed; reconnecting hop", options: managed.launchOptions)
                }
            }
        }
    }

    private func isReady(_ controlMaster: JumpHostControlMaster) -> Bool {
        guard JumpHostControlMasterFactory.requiresReadyMarker(for: controlMaster.jumpHost) else {
            return true
        }
        return FileManager.default.fileExists(atPath: controlMaster.readyPath.path)
    }

    func runHealthCheckForTesting() {
        queue.sync {
            checkHealthLocked()
        }
    }
}

private struct HopCredentials {
    var password: String?
    var totp: HopSecretReference?
}

private struct HopSecretReference {
    var service: String
    var account: String
}

private final class ManagedHopConnection {
    enum StopReason {
        case user
        case restart
        case replacement
    }

    let profile: TunnelProfile
    let controlMaster: JumpHostControlMaster
    let credentials: HopCredentials
    let launchOptions: SSHLaunchOptions
    let startedAt: Date
    let readinessMarker: JumpHostReadinessMarker?
    var session: SSHProcessSession!
    var outputBuffer = Data()
    var redactedSecrets: [String]
    var redactor: SSHTranscriptRedactor
    var stopReason: StopReason?
    var hasExistingSessionConflict = false
    var sentHostKeyConfirmation = false
    var sentPassword = false
    var sentTOTP = false

    var matchesExistingSessionConflict: Bool {
        guard let text = String(data: outputBuffer, encoding: .utf8) else {
            return false
        }
        return HopConnectionManager.matchesExistingSessionMessage(in: text)
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

    init(profile: TunnelProfile, controlMaster: JumpHostControlMaster, credentials: HopCredentials, launchOptions: SSHLaunchOptions, startedAt: Date) {
        self.profile = profile
        self.controlMaster = controlMaster
        self.credentials = credentials
        self.launchOptions = launchOptions
        self.startedAt = startedAt
        readinessMarker = JumpHostReadinessMarker(controlMaster: controlMaster)
        let initialSecrets = [credentials.password].compactMap(\.self)
        redactedSecrets = initialSecrets
        redactor = SSHTranscriptRedactor(secrets: initialSecrets)
    }

    func addRedactedSecret(_ secret: String) {
        redactedSecrets.append(secret)
        redactor.addSecret(secret)
    }
}
