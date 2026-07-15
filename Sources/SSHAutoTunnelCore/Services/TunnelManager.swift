import Foundation

public final class TunnelManager {
    public var onStatusChange: ((TunnelRuntimeStatus) -> Void)?
    public var onLog: ((UUID, String) -> Void)?
    public var onKeychainAccessCompleted: (() -> Void)?

    private let keychain: GenericPasswordReading
    private let processLauncher: SSHProcessLaunching
    private let socks5Probe: (Int) -> Bool
    private let socksPortAllocator: (Int, Set<Int>) throws -> RuntimeSocksPortAllocation
    private let preferredSocksPortAvailable: (Int) -> Bool
    private let tunnelProcessRegistry: TunnelProcessRecording
    private let tunnelProcessReclaimer: TunnelProcessReclaiming
    private let attemptLedger: SSHConnectionAttemptLedger
    private let reconnectDelay: (Int) -> TimeInterval
    private let totpGenerator: (String) throws -> String
    private let initialReadinessGracePeriod: TimeInterval
    private let healthyResetInterval: TimeInterval
    private let processExitOutputSettleDelay: TimeInterval
    private let stopForceKillDelay: TimeInterval
    private let stopVerificationDelay: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.clange.ssh-autotunnel.tunnels")
    private var processes: [UUID: ManagedTunnel] = [:]
    private var terminatingProcesses: [Int32: ManagedTunnel] = [:]
    private var statuses: [UUID: TunnelRuntimeStatus] = [:]
    private var reconnectTokens: [UUID: UUID] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var pendingReconnects: [UUID: PendingTunnelReconnect] = [:]
    private var reconnectPrerequisiteMessages: [UUID: String] = [:]
    private var networkPathState: SSHNetworkPathState
    private var healthTimer: DispatchSourceTimer?

    public convenience init(
        keychain: GenericPasswordReading = KeychainService(),
        attemptLedger: SSHConnectionAttemptLedger = SSHConnectionAttemptLedger(),
        initialNetworkPathState: SSHNetworkPathState = .satisfied
    ) {
        let tunnelProcessRegistry = TunnelProcessRegistry()
        self.init(
            keychain: keychain,
            processLauncher: PTYSSHProcessLauncher(),
            socks5Probe: { SOCKS5Probe.probe(port: $0) },
            preferredSocksPortAvailable: LoopbackPortProbe.canBind,
            tunnelProcessRegistry: tunnelProcessRegistry,
            tunnelProcessReclaimer: TunnelProcessReclaimer(registry: tunnelProcessRegistry),
            attemptLedger: attemptLedger,
            initialNetworkPathState: initialNetworkPathState,
            reconnectDelay: {
                TunnelLifecyclePolicy.reconnectDelay(
                    forAttempt: $0,
                    jitterFraction: Double.random(in: 0...0.2)
                )
            },
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
        preferredSocksPortAvailable: @escaping (Int) -> Bool = { _ in true },
        tunnelProcessRegistry: TunnelProcessRecording = NoopTunnelProcessRegistry(),
        tunnelProcessReclaimer: TunnelProcessReclaiming = NoopTunnelProcessReclaimer(),
        attemptLedger: SSHConnectionAttemptLedger = SSHConnectionAttemptLedger(),
        initialNetworkPathState: SSHNetworkPathState = .satisfied,
        reconnectDelay: @escaping (Int) -> TimeInterval = { TunnelLifecyclePolicy.reconnectDelay(forAttempt: $0) },
        totpGenerator: @escaping (String) throws -> String = { try TOTPGenerator.generate(secretBase32: $0) },
        initialReadinessGracePeriod: TimeInterval = 60,
        healthyResetInterval: TimeInterval = TunnelLifecyclePolicy.healthyResetInterval,
        processExitOutputSettleDelay: TimeInterval = 0.05,
        stopForceKillDelay: TimeInterval = 2.0,
        stopVerificationDelay: TimeInterval = 1.0,
        now: @escaping () -> Date = Date.init,
        startsHealthTimer: Bool = true
    ) {
        self.keychain = keychain
        self.processLauncher = processLauncher
        self.socks5Probe = socks5Probe
        self.socksPortAllocator = socksPortAllocator
        self.preferredSocksPortAvailable = preferredSocksPortAvailable
        self.tunnelProcessRegistry = tunnelProcessRegistry
        self.tunnelProcessReclaimer = tunnelProcessReclaimer
        self.attemptLedger = attemptLedger
        self.networkPathState = initialNetworkPathState
        self.reconnectDelay = reconnectDelay
        self.totpGenerator = totpGenerator
        self.initialReadinessGracePeriod = initialReadinessGracePeriod
        self.healthyResetInterval = healthyResetInterval
        self.processExitOutputSettleDelay = processExitOutputSettleDelay
        self.stopForceKillDelay = stopForceKillDelay
        self.stopVerificationDelay = stopVerificationDelay
        self.now = now
        tunnelProcessRegistry.pruneInactive()
        if startsHealthTimer {
            startHealthTimer()
        }
    }

    deinit {
        healthTimer?.cancel()
        reconnectTokens.removeAll()
        reconnectAttempts.removeAll()
        pendingReconnects.removeAll()
        for managed in allManagedTunnelsLocked() {
            managed.stopReason = .user
            if managed.session?.isRunning == true {
                managed.session.terminate()
                managed.session.forceKill()
            }
        }
        processes.removeAll()
        terminatingProcesses.removeAll()
    }

    public func status(for profileID: UUID) -> TunnelRuntimeStatus {
        queue.sync {
            statuses[profileID] ?? TunnelRuntimeStatus(profileID: profileID)
        }
    }

    public func allStatuses() -> [UUID: TunnelRuntimeStatus] {
        queue.sync { statuses }
    }

    public func updateNetworkPathState(_ state: SSHNetworkPathState) {
        queue.async {
            self.networkPathState = state
            if state.permitsSSHLaunch {
                self.resumePendingReconnectsLocked()
            } else {
                self.pausePendingReconnectsLocked()
            }
        }
    }

    public func updateReconnectPrerequisite(
        profileID: UUID,
        available: Bool,
        terminalReason: String? = nil
    ) {
        queue.async {
            if available {
                self.reconnectPrerequisiteMessages[profileID] = nil
                self.armPendingReconnectLocked(profileID: profileID)
                return
            }

            let message = terminalReason ?? "Waiting for hop connection; no SSH attempt will be made."
            self.reconnectPrerequisiteMessages[profileID] = message
            self.reconnectTokens[profileID] = nil
            if let terminalReason {
                self.pendingReconnects[profileID] = nil
                self.reconnectAttempts[profileID] = nil
                self.stopLocked(profileID: profileID, updateStatus: false, reason: .user)
                self.updateStatusLocked(profileID, .failed, terminalReason, pid: nil)
            } else if self.pendingReconnects[profileID] != nil {
                self.updateStatusLocked(profileID, .reconnecting, message, pid: nil)
                self.logEventLocked("automatic reconnect paused while waiting for the hop", profileID: profileID)
            }
        }
    }

    public func start(profile: TunnelProfile, options: SSHLaunchOptions = .standard, reservedSocksPorts: Set<Int> = []) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.pendingReconnects[profile.id] = nil
            self.reconnectPrerequisiteMessages[profile.id] = nil
            self.startLocked(
                profile: profile,
                message: "Starting tunnel",
                options: options,
                reservedSocksPorts: reservedSocksPorts,
                origin: .userInitiated
            )
        }
    }

    public func stop(profileID: UUID) {
        queue.async {
            self.reconnectTokens[profileID] = nil
            self.reconnectAttempts[profileID] = nil
            self.pendingReconnects[profileID] = nil
            self.reconnectPrerequisiteMessages[profileID] = nil
            self.stopLocked(profileID: profileID, updateStatus: true, reason: .user)
        }
    }

    public func stopAll() {
        queue.sync {
            reconnectTokens.removeAll()
            reconnectAttempts.removeAll()
            pendingReconnects.removeAll()
            reconnectPrerequisiteMessages.removeAll()
            let profileIDs = Set(processes.keys).union(terminatingProcesses.values.map { $0.profile.id })
            for profileID in profileIDs {
                stopLocked(profileID: profileID, updateStatus: true, reason: .user)
            }
        }
    }

    @discardableResult
    public func stopAllWaiting(upTo timeout: TimeInterval, forceKillAfter: TimeInterval = 2.0) -> Bool {
        let managedTunnels = queue.sync {
            reconnectTokens.removeAll()
            reconnectAttempts.removeAll()
            pendingReconnects.removeAll()
            reconnectPrerequisiteMessages.removeAll()
            let managedTunnels = allManagedTunnelsLocked()
            for managed in managedTunnels {
                managed.stopReason = .user
                managed.stopUpdatesStatus = true
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
                if terminatingProcesses[managed.session.processIdentifier] === managed {
                    terminatingProcesses[managed.session.processIdentifier] = nil
                }
                tunnelProcessRegistry.remove(profileID: managed.profile.id, pid: managed.session.processIdentifier)
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

    private func allManagedTunnelsLocked() -> [ManagedTunnel] {
        var managedTunnels = Array(processes.values)
        let activePIDs = Set(managedTunnels.map { $0.session.processIdentifier })
        managedTunnels.append(contentsOf: terminatingProcesses.values.filter { !activePIDs.contains($0.session.processIdentifier) })
        return managedTunnels
    }

    public func reconnect(profile: TunnelProfile, options: SSHLaunchOptions = .standard, reservedSocksPorts: Set<Int> = []) {
        queue.async {
            self.reconnectTokens[profile.id] = nil
            self.reconnectAttempts[profile.id] = 0
            self.pendingReconnects[profile.id] = nil
            self.reconnectPrerequisiteMessages[profile.id] = nil
            self.stopLocked(profileID: profile.id, updateStatus: false, reason: .restart)
            let token = UUID()
            self.reconnectTokens[profile.id] = token
            self.updateStatusLocked(profile.id, .reconnecting, "Reconnect requested", pid: nil)
            self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.reconnectTokens[profile.id] == token else { return }
                self.reconnectTokens[profile.id] = nil
                self.startLocked(
                    profile: profile,
                    message: "Reconnecting",
                    options: options,
                    reservedSocksPorts: reservedSocksPorts,
                    origin: .userInitiated
                )
            }
        }
    }

    private func startLocked(
        profile: TunnelProfile,
        message: String,
        options: SSHLaunchOptions,
        reservedSocksPorts: Set<Int>,
        excludedSocksPorts: Set<Int> = [],
        hasRetriedAppForwardingFailure: Bool = false,
        origin: SSHConnectionLaunchOrigin
    ) {
        guard networkPathState.permitsSSHLaunch else {
            reconnectTokens[profile.id] = nil
            if origin == .userInitiated {
                reconnectAttempts[profile.id] = nil
                updateStatusLocked(
                    profile.id,
                    .failed,
                    "No network connection; no SSH attempt was made.",
                    pid: nil
                )
            }
            return
        }
        stopLocked(profileID: profile.id, updateStatus: false, reason: .replacement)
        let launchHealth: TunnelHealth = origin == .automatic ? .reconnecting : .connecting
        updateStatusLocked(profile.id, launchHealth, message, pid: nil)
        do {
            try reclaimConfiguredPortIfNeeded(
                profile: profile,
                excludedSocksPorts: excludedSocksPorts
            )
            let runtimeProfile = try runtimeProfile(for: profile, reservedSocksPorts: reservedSocksPorts, excludedSocksPorts: excludedSocksPorts)
            if runtimeProfile.localSocksPort != profile.localSocksPort {
                logEventLocked(
                    "local SOCKS port \(profile.localSocksPort) unavailable; using \(runtimeProfile.localSocksPort) for this run",
                    profileID: profile.id
                )
            }
            let credentials = try credentials(for: profile)
            try runKerberosSwitchIfNeeded(profile: profile)
            let endpoint = SSHConnectionEndpoint(profile: runtimeProfile)
            let reservation = try automaticAttemptReservationIfNeeded(origin: origin, endpoint: endpoint)
            let managed: ManagedTunnel
            do {
                managed = try launch(
                    profile: profile,
                    runtimeProfile: runtimeProfile,
                    credentials: credentials,
                    options: options,
                    reservedSocksPorts: reservedSocksPorts,
                    excludedSocksPorts: excludedSocksPorts,
                    hasRetriedAppForwardingFailure: hasRetriedAppForwardingFailure
                )
            } catch {
                if let reservation {
                    attemptLedger.cancel(reservation)
                }
                throw error
            }
            if origin == .userInitiated {
                attemptLedger.recordUserInitiatedAttempt(to: endpoint, at: now())
            }
            processes[profile.id] = managed
            let startedMessage: String
            if origin == .automatic {
                let attempt = reconnectAttempts[profile.id] ?? 1
                let limit = TunnelLifecyclePolicy.effectiveReconnectAttemptLimit(profile.curatedSSHOptions.maxReconnectAttempts)
                startedMessage = "Automatic reconnect attempt \(attempt) of \(limit) started"
            } else {
                startedMessage = "SSH process started"
            }
            updateStatusLocked(
                profile.id,
                launchHealth,
                startedMessage,
                pid: managed.session.processIdentifier,
                effectiveLocalSocksPort: runtimeProfile.localSocksPort
            )
        } catch {
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            pendingReconnects[profile.id] = nil
            let message = origin == .automatic
                ? "\(error.localizedDescription) Automatic reconnect stopped; no further automatic attempts will occur."
                : "\(error.localizedDescription) No automatic retry will be attempted."
            updateStatusLocked(profile.id, .failed, message, pid: nil)
        }
    }

    private func automaticAttemptReservationIfNeeded(
        origin: SSHConnectionLaunchOrigin,
        endpoint: SSHConnectionEndpoint
    ) throws -> SSHConnectionAttemptLedger.Reservation? {
        guard origin == .automatic else { return nil }
        guard let reservation = attemptLedger.reserveAutomaticAttempt(to: endpoint, at: now()) else {
            throw SSHAutomaticAttemptLimitError(endpoint: endpoint)
        }
        return reservation
    }

    private func reclaimConfiguredPortIfNeeded(profile: TunnelProfile, excludedSocksPorts: Set<Int>) throws {
        guard !excludedSocksPorts.contains(profile.localSocksPort) else { return }

        let result = tunnelProcessReclaimer.reclaimStaleProcesses(
            for: profile,
            configuredPort: profile.localSocksPort,
            activePIDs: activeTunnelPIDs()
        )
        for reclaimed in result.reclaimed {
            logEventLocked(
                "reclaimed stale SSH tunnel pid \(reclaimed.pid) on 127.0.0.1:\(reclaimed.port) (\(reclaimed.reason))",
                profileID: profile.id
            )
        }
        if let blocker = result.blockers.first {
            let pidDetail = blocker.pid.map { "pid \($0), " } ?? ""
            throw TunnelProcessReclaimError(port: blocker.port, reason: "\(pidDetail)\(blocker.reason)")
        }

        guard preferredSocksPortAvailable(profile.localSocksPort) else {
            throw TunnelProcessReclaimError(
                port: profile.localSocksPort,
                reason: "port is still occupied after stale-process reclamation; refusing to switch to an alternate SOCKS port"
            )
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

    private func activeTunnelPIDs() -> Set<Int32> {
        Set(processes.values.compactMap { managed in
            managed.session?.processIdentifier
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
                    self.observeProcessTerminationLocked(managed, terminationStatus: session.terminationStatus)
                }
            }
        )
        tunnelProcessRegistry.upsert(
            TunnelProcessRecord(
                profileID: profile.id,
                profileName: profile.name,
                configuredSocksPort: profile.localSocksPort,
                effectiveSocksPort: runtimeProfile.localSocksPort,
                pid: managed.session.processIdentifier,
                command: command,
                startedAt: managed.startedAt
            )
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
                    "SSH host key prompt blocked by \(tunnel.profile.hostKeyPolicy.displayName) policy. No further automatic attempts will occur.",
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
                        "Could not generate TOTP: \(error.localizedDescription). No further automatic attempts will occur.",
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
                if let stopping = terminatingProcesses.values.first(where: { $0.profile.id == profileID }) {
                    updateStatusLocked(
                        profileID,
                        .stopping,
                        "Stopping SSH process",
                        pid: stopping.session.processIdentifier,
                        effectiveLocalSocksPort: stopping.runtimeProfile.localSocksPort
                    )
                } else {
                    updateStatusLocked(profileID, .stopped, "Stopped", pid: nil)
                }
            }
            return
        }
        flushRedactedOutputLocked(managed)
        managed.stopReason = reason
        managed.stopUpdatesStatus = updateStatus
        if managed.session.isRunning {
            terminatingProcesses[managed.session.processIdentifier] = managed
            logEventLocked("termination requested; sending SIGTERM to pid \(managed.session.processIdentifier)", profileID: profileID)
            if updateStatus {
                updateStatusLocked(
                    profileID,
                    .stopping,
                    "Stopping SSH process",
                    pid: managed.session.processIdentifier,
                    effectiveLocalSocksPort: managed.runtimeProfile.localSocksPort
                )
            }
            managed.session.terminate()
            queue.asyncAfter(deadline: .now() + stopForceKillDelay) { [weak self, managed] in
                self?.forceKillIfStillStoppingLocked(managed)
            }
        } else {
            terminatingProcesses[managed.session.processIdentifier] = managed
            observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
        }
    }

    private func forceKillIfStillStoppingLocked(_ managed: ManagedTunnel) {
        guard terminatingProcesses[managed.session.processIdentifier] === managed else { return }
        guard managed.session.isRunning else {
            observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
            return
        }
        logEventLocked("still running after stop timeout; sending SIGKILL to pid \(managed.session.processIdentifier)", profileID: managed.profile.id)
        managed.session.forceKill()
        queue.asyncAfter(deadline: .now() + stopVerificationDelay) { [weak self, managed] in
            self?.verifyStoppedAfterForceKillLocked(managed)
        }
    }

    private func verifyStoppedAfterForceKillLocked(_ managed: ManagedTunnel) {
        guard terminatingProcesses[managed.session.processIdentifier] === managed else { return }
        guard managed.session.isRunning else {
            observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
            return
        }
        if managed.stopUpdatesStatus {
            updateStatusLocked(
                managed.profile.id,
                .failed,
                "Could not stop SSH process after SIGKILL",
                pid: managed.session.processIdentifier,
                effectiveLocalSocksPort: managed.runtimeProfile.localSocksPort
            )
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
            pendingReconnects[profile.id] = nil
            updateStatusLocked(profile.id, .stopped, sshExitMessage(status: terminationStatus, detail: exitDetail), pid: nil)
        case .markFailed:
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            pendingReconnects[profile.id] = nil
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
        guard isTrackedLocked(managed) else { return }
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
        guard isTrackedLocked(managed),
              let terminationStatus = managed.observedTerminationStatus else {
            return
        }

        flushRedactedOutputLocked(managed)
        let wasTerminating = terminatingProcesses[managed.session.processIdentifier] === managed
        if processes[managed.profile.id] === managed {
            processes[managed.profile.id] = nil
        }
        if wasTerminating {
            terminatingProcesses[managed.session.processIdentifier] = nil
        }
        tunnelProcessRegistry.remove(profileID: managed.profile.id, pid: managed.session.processIdentifier)

        if wasTerminating {
            if managed.stopUpdatesStatus {
                updateStatusLocked(managed.profile.id, .stopped, "Stopped", pid: nil)
            }
            return
        }

        let forwardingFailure = managed.forwardingFailure
        if shouldRetryAppForwardingFailure(forwardingFailure, managed: managed) {
            let failedPort = managed.runtimeProfile.localSocksPort
            logEventLocked("local SOCKS port \(failedPort) became unavailable; scheduling one alternate-port retry", profileID: managed.profile.id)
            scheduleReconnectLocked(
                profile: managed.profile,
                message: "Local SOCKS port became unavailable",
                options: managed.launchOptions,
                reservedSocksPorts: managed.reservedSocksPorts,
                excludedSocksPorts: managed.excludedSocksPorts.union([failedPort]),
                hasRetriedAppForwardingFailure: true
            )
            return
        }

        let campaignIsActive = (reconnectAttempts[managed.profile.id] ?? 0) > 0
        let failureDisposition = SSHConnectionFailureClassifier.disposition(
            transcript: managed.redactedTranscript,
            reachedHealthyState: managed.reachedHealthy
        )
        let decision: TunnelLifecyclePolicy.ProcessExitDecision
        if forwardingFailure != nil, managed.stopReason == nil {
            decision = .markFailed
        } else {
            decision = TunnelLifecyclePolicy.processExitDecision(
                terminationStatus: terminationStatus,
                wasIntentionalStop: managed.stopReason != nil,
                autoReconnect: managed.profile.autoReconnect,
                canAutomaticallyReconnect: managed.reachedHealthy || campaignIsActive,
                failureIsRetryable: failureDisposition == .retryable
            )
        }

        var exitDetail = forwardingFailure?.statusDetail ?? managed.lastOutputLine
        if failureDisposition == .terminal, managed.stopReason == nil {
            let detail = exitDetail.map { "\($0); " } ?? ""
            exitDetail = "\(detail)authentication or host-key failure is not retryable; automatic reconnect stopped and no more attempts will be made"
        } else if !managed.reachedHealthy, !campaignIsActive, managed.stopReason == nil, managed.profile.autoReconnect {
            let detail = exitDetail.map { "\($0); " } ?? ""
            exitDetail = "\(detail)automatic reconnect was not started because this connection never became healthy"
        } else if decision == .markFailed, managed.stopReason == nil {
            let detail = exitDetail.map { "\($0); " } ?? ""
            exitDetail = "\(detail)automatic reconnect is disabled or this failure is not retryable; no further automatic attempts will occur"
        }

        applyProcessExitDecisionLocked(
            decision,
            profile: managed.profile,
            options: managed.launchOptions,
            terminationStatus: terminationStatus,
            exitDetail: exitDetail,
            reservedSocksPorts: managed.reservedSocksPorts
        )
    }

    private func isTrackedLocked(_ managed: ManagedTunnel) -> Bool {
        processes[managed.profile.id] === managed
            || terminatingProcesses[managed.session.processIdentifier] === managed
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
        reservedSocksPorts: Set<Int>,
        excludedSocksPorts: Set<Int> = [],
        hasRetriedAppForwardingFailure: Bool = false
    ) {
        let attempt = (reconnectAttempts[profile.id] ?? 0) + 1
        let limit = TunnelLifecyclePolicy.effectiveReconnectAttemptLimit(profile.curatedSSHOptions.maxReconnectAttempts)
        if attempt > limit {
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            pendingReconnects[profile.id] = nil
            updateStatusLocked(
                profile.id,
                .failed,
                "Automatic reconnect stopped after \(limit) failed attempts; no more automatic attempts will be made",
                pid: nil
            )
            logEventLocked("automatic reconnect stopped after \(limit) failed attempts", profileID: profile.id)
            return
        }
        reconnectAttempts[profile.id] = attempt
        let delay = explicitDelay ?? reconnectDelay(attempt)
        pendingReconnects[profile.id] = PendingTunnelReconnect(
            profile: profile,
            message: message,
            options: options,
            reservedSocksPorts: reservedSocksPorts,
            excludedSocksPorts: excludedSocksPorts,
            hasRetriedAppForwardingFailure: hasRetriedAppForwardingFailure,
            attempt: attempt,
            limit: limit,
            eligibleAt: now().addingTimeInterval(delay)
        )
        logEventLocked("reconnect attempt \(attempt) scheduled in \(String(format: "%.1f", delay))s", profileID: profile.id)
        armPendingReconnectLocked(profileID: profile.id)
    }

    private func pausePendingReconnectsLocked() {
        for profileID in pendingReconnects.keys {
            reconnectTokens[profileID] = nil
            updateStatusLocked(
                profileID,
                .reconnecting,
                "Waiting for network; no SSH attempt will be made.",
                pid: nil
            )
            logEventLocked("automatic reconnect paused while waiting for a usable network path", profileID: profileID)
        }
    }

    private func resumePendingReconnectsLocked() {
        for profileID in pendingReconnects.keys {
            armPendingReconnectLocked(profileID: profileID)
        }
    }

    private func armPendingReconnectLocked(profileID: UUID) {
        guard let pending = pendingReconnects[profileID] else { return }
        guard networkPathState.permitsSSHLaunch else {
            reconnectTokens[profileID] = nil
            updateStatusLocked(
                profileID,
                .reconnecting,
                "Waiting for network; no SSH attempt will be made.",
                pid: nil
            )
            return
        }
        if let prerequisiteMessage = reconnectPrerequisiteMessages[profileID] {
            reconnectTokens[profileID] = nil
            updateStatusLocked(profileID, .reconnecting, prerequisiteMessage, pid: nil)
            return
        }

        let remainingDelay = max(0, pending.eligibleAt.timeIntervalSince(now()))
        let token = UUID()
        reconnectTokens[profileID] = token
        updateStatusLocked(
            profileID,
            .reconnecting,
            "\(pending.message); retry \(pending.attempt) of \(pending.limit) in \(Self.retryDelayDescription(remainingDelay))",
            pid: nil
        )

        queue.asyncAfter(deadline: .now() + remainingDelay) { [weak self] in
            guard let self,
                  self.reconnectTokens[profileID] == token,
                  let pending = self.pendingReconnects[profileID],
                  self.networkPathState.permitsSSHLaunch,
                  self.reconnectPrerequisiteMessages[profileID] == nil else {
                return
            }
            self.reconnectTokens[profileID] = nil
            self.pendingReconnects[profileID] = nil
            self.startLocked(
                profile: pending.profile,
                message: "Reconnecting",
                options: pending.options,
                reservedSocksPorts: pending.reservedSocksPorts,
                excludedSocksPorts: pending.excludedSocksPorts,
                hasRetriedAppForwardingFailure: pending.hasRetriedAppForwardingFailure,
                origin: .automatic
            )
        }
    }

    private static func retryDelayDescription(_ delay: TimeInterval) -> String {
        if delay < 10 {
            return "\(Int(ceil(delay))) seconds"
        }
        if delay < 60 {
            return "\(Int(round(delay))) seconds"
        }
        let minutes = Int(round(delay / 60))
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
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
        finalizeExitedTerminatingProcessesLocked()
        for (profileID, managed) in Array(processes) {
            if managed.observedTerminationStatus != nil {
                continue
            }

            guard managed.session.isRunning else {
                observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
                continue
            }

            if socks5Probe(managed.runtimeProfile.localSocksPort) {
                if !managed.reachedHealthy {
                    managed.reachedHealthy = true
                    managed.healthySince = now()
                }
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
                if let healthySince = managed.healthySince,
                   now().timeIntervalSince(healthySince) >= healthyResetInterval {
                    reconnectAttempts[profileID] = 0
                }
            } else {
                let hasInitialReadinessGraceExpired = now().timeIntervalSince(managed.startedAt) >= initialReadinessGracePeriod
                let campaignIsActive = (reconnectAttempts[profileID] ?? 0) > 0
                if hasInitialReadinessGraceExpired, !managed.reachedHealthy, !campaignIsActive {
                    stopLocked(profileID: profileID, updateStatus: false, reason: .user)
                    updateStatusLocked(
                        profileID,
                        .failed,
                        "Initial SSH connection did not become healthy; automatic reconnect was not started",
                        pid: nil
                    )
                    continue
                }
                let decision = TunnelLifecyclePolicy.healthProbeFailureDecision(
                    previousHealth: statuses[profileID]?.health,
                    autoReconnect: managed.profile.autoReconnect && (managed.reachedHealthy || campaignIsActive),
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

    private func finalizeExitedTerminatingProcessesLocked() {
        for managed in Array(terminatingProcesses.values) where !managed.session.isRunning {
            observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
        }
    }

    func runHealthCheckForTesting() {
        queue.sync {
            checkHealthLocked()
        }
    }
}

private struct PendingTunnelReconnect {
    var profile: TunnelProfile
    var message: String
    var options: SSHLaunchOptions
    var reservedSocksPorts: Set<Int>
    var excludedSocksPorts: Set<Int>
    var hasRetriedAppForwardingFailure: Bool
    var attempt: Int
    var limit: Int
    var eligibleAt: Date
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
    var stopUpdatesStatus = false
    var observedTerminationStatus: Int32?
    var reachedHealthy = false
    var healthySince: Date?
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

    var redactedTranscript: String {
        guard let text = String(data: outputBuffer, encoding: .utf8) else { return "" }
        return SSHTranscriptLog.redact(text, secrets: redactedSecrets)
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
