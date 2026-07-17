import Foundation

public final class HopConnectionManager {
    public var onStatusChange: ((HopRuntimeStatus) -> Void)?
    public var onLog: ((UUID, String) -> Void)?
    public var onKeychainAccessCompleted: (() -> Void)?

    private let keychain: GenericPasswordReading
    private let processLauncher: SSHProcessLaunching
    private let ownershipManager: HopControlMasterOwnershipManaging
    private let healthCheck: (JumpHostControlMaster) -> Bool
    private let attemptLedger: SSHConnectionAttemptLedger
    private let reconnectDelay: (Int) -> TimeInterval
    private let totpGenerator: (String) throws -> String
    private let initialReadinessGracePeriod: TimeInterval
    private let healthyResetInterval: TimeInterval
    private let processExitObservationDelay: TimeInterval
    private let stopForceKillDelay: TimeInterval
    private let stopVerificationDelay: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.clange.ssh-autotunnel.hops")
    private var processes: [UUID: ManagedHopConnection] = [:]
    private var terminatingProcesses: [Int32: ManagedHopConnection] = [:]
    private var statuses: [UUID: HopRuntimeStatus] = [:]
    private var reconnectTokens: [UUID: UUID] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var pendingSharedProfiles: [UUID: [TunnelProfile]] = [:]
    private var pendingReconnects: [UUID: PendingHopReconnect] = [:]
    private var networkPathState: SSHNetworkPathState
    private var healthTimer: DispatchSourceTimer?

    public convenience init(
        keychain: GenericPasswordReading = KeychainService(),
        attemptLedger: SSHConnectionAttemptLedger = SSHConnectionAttemptLedger(),
        initialNetworkPathState: SSHNetworkPathState = .satisfied
    ) {
        self.init(
            keychain: keychain,
            processLauncher: PTYSSHProcessLauncher(),
            ownershipManager: FileHopControlMasterOwnershipManager(),
            healthCheck: { controlMaster in
                (try? ShellRunner.run("/usr/bin/ssh", ["-S", controlMaster.controlPath, "-O", "check", controlMaster.jumpHost]).exitCode) == 0
            },
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
        ownershipManager: HopControlMasterOwnershipManaging = NoopHopControlMasterOwnershipManager(),
        healthCheck: @escaping (JumpHostControlMaster) -> Bool,
        attemptLedger: SSHConnectionAttemptLedger = SSHConnectionAttemptLedger(),
        initialNetworkPathState: SSHNetworkPathState = .satisfied,
        reconnectDelay: @escaping (Int) -> TimeInterval = { TunnelLifecyclePolicy.reconnectDelay(forAttempt: $0) },
        totpGenerator: @escaping (String) throws -> String = { try TOTPGenerator.generate(secretBase32: $0) },
        initialReadinessGracePeriod: TimeInterval = 60,
        healthyResetInterval: TimeInterval = TunnelLifecyclePolicy.healthyResetInterval,
        processExitObservationDelay: TimeInterval = 0.1,
        stopForceKillDelay: TimeInterval = 2.0,
        stopVerificationDelay: TimeInterval = 1.0,
        now: @escaping () -> Date = Date.init,
        startsHealthTimer: Bool = true
    ) {
        self.keychain = keychain
        self.processLauncher = processLauncher
        self.ownershipManager = ownershipManager
        self.healthCheck = healthCheck
        self.attemptLedger = attemptLedger
        self.networkPathState = initialNetworkPathState
        self.reconnectDelay = reconnectDelay
        self.totpGenerator = totpGenerator
        self.initialReadinessGracePeriod = initialReadinessGracePeriod
        self.healthyResetInterval = healthyResetInterval
        self.processExitObservationDelay = processExitObservationDelay
        self.stopForceKillDelay = stopForceKillDelay
        self.stopVerificationDelay = stopVerificationDelay
        self.now = now
        if startsHealthTimer {
            startHealthTimer()
        }
    }

    deinit {
        healthTimer?.cancel()
        reconnectTokens.removeAll()
        reconnectAttempts.removeAll()
        pendingReconnects.removeAll()
        pendingSharedProfiles.removeAll()
        for managed in allManagedHopsLocked() {
            managed.stopReason = .user
            if managed.session?.isRunning == true {
                managed.session.terminate()
                managed.session.forceKill()
            }
            ownershipManager.cleanup(managed.controlMaster, sessionPID: managed.session.processIdentifier)
        }
        processes.removeAll()
        terminatingProcesses.removeAll()
    }

    public func status(for profileID: UUID) -> HopRuntimeStatus? {
        queue.sync {
            statuses[profileID]
        }
    }

    public func allStatuses() -> [UUID: HopRuntimeStatus] {
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
            self.pendingReconnects[profile.id] = nil
            self.pendingSharedProfiles[profile.id] = nil
            self.startLocked(profile: profile, message: "Starting hop connection", options: options, origin: .userInitiated)
        }
    }

    public func stop(profileID: UUID) {
        queue.async {
            self.reconnectTokens[profileID] = nil
            self.reconnectAttempts[profileID] = nil
            self.removePendingReconnectLocked(containing: profileID)
            self.stopLocked(profileID: profileID, updateStatus: true, reason: .user)
        }
    }

    public func stopAll() {
        queue.sync {
            reconnectTokens.removeAll()
            reconnectAttempts.removeAll()
            pendingReconnects.removeAll()
            pendingSharedProfiles.removeAll()
            let profileIDs = Set(processes.keys).union(terminatingProcesses.values.map { $0.profile.id })
            for profileID in profileIDs {
                stopLocked(profileID: profileID, updateStatus: true, reason: .user)
            }
        }
    }

    @discardableResult
    public func stopAllWaiting(upTo timeout: TimeInterval, forceKillAfter: TimeInterval = 2.0) -> Bool {
        let managedHops = queue.sync {
            reconnectTokens.removeAll()
            reconnectAttempts.removeAll()
            pendingReconnects.removeAll()
            pendingSharedProfiles.removeAll()
            let managedHops = allManagedHopsLocked()
            for managed in managedHops {
                managed.stopReason = .user
                managed.stopUpdatesStatus = true
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
                for id in managed.profiles.keys where processes[id] === managed {
                    processes[id] = nil
                }
                if terminatingProcesses[managed.session.processIdentifier] === managed {
                    terminatingProcesses[managed.session.processIdentifier] = nil
                }
                ownershipManager.cleanup(managed.controlMaster, sessionPID: managed.session.processIdentifier)
                if managed.session.isRunning {
                    updateManagedStatusLocked(managed, .failed, "Could not stop SSH hop process before timeout", pid: managed.session.processIdentifier)
                } else {
                    updateManagedStatusLocked(managed, .stopped, "Stopped", pid: nil)
                }
            }
        }
        return didExit
    }

    private func allManagedHopsLocked() -> [ManagedHopConnection] {
        var seen: Set<ObjectIdentifier> = []
        var managedHops = Array(processes.values.filter { seen.insert(ObjectIdentifier($0)).inserted })
        let activePIDs = Set(managedHops.map { $0.session.processIdentifier })
        managedHops.append(contentsOf: terminatingProcesses.values.filter {
            !activePIDs.contains($0.session.processIdentifier) && seen.insert(ObjectIdentifier($0)).inserted
        })
        return managedHops
    }

    public func reconnect(profile: TunnelProfile, options: SSHLaunchOptions = .standard) {
        queue.async {
            guard let managed = self.processes[profile.id] else {
                self.reconnectTokens[profile.id] = nil
                self.reconnectAttempts[profile.id] = 0
                self.removePendingReconnectLocked(containing: profile.id)
                self.scheduleUserInitiatedStartLocked(profile: profile, message: "Reconnecting hop", delay: 1.0, options: options)
                return
            }
            var sharedProfiles = managed.profiles
            sharedProfiles[profile.id] = profile
            let sharedValues = Array(sharedProfiles.values)
            let primary = sharedValues.first(where: { $0.id == profile.id }) ?? profile
            for shared in sharedValues {
                self.reconnectTokens[shared.id] = nil
                self.reconnectAttempts[shared.id] = 0
                self.removePendingReconnectLocked(containing: shared.id)
            }
            managed.pendingStart = .init(
                profile: primary,
                profiles: sharedValues,
                message: "Reconnecting hop",
                options: options,
                delay: 1.0,
                origin: .userInitiated
            )
            self.stopManagedHopLocked(for: profile.id, updateStatus: false, reason: .restart)
        }
    }

    private func startLocked(
        profile: TunnelProfile,
        message: String,
        options: SSHLaunchOptions,
        origin: SSHConnectionLaunchOrigin
    ) {
        guard networkPathState.permitsSSHLaunch else {
            reconnectTokens[profile.id] = nil
            if origin == .userInitiated {
                reconnectAttempts[profile.id] = nil
                let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                updateStatusLocked(
                    profile.id,
                    jumpHost: jumpHost,
                    .failed,
                    "No network connection; no SSH attempt was made.",
                    pid: nil
                )
            }
            return
        }
        do {
            let controlMaster = try JumpHostControlMasterFactory.make(for: profile, options: options)
            if let current = processes[profile.id],
               current.controlMaster.endpoint == controlMaster.endpoint,
               current.controlMaster.signature == controlMaster.signature,
               current.session.isRunning {
                if current.launchOptions != options {
                    var sharedProfiles = current.profiles
                    sharedProfiles[profile.id] = profile
                    current.pendingStart = .init(
                        profile: profile,
                        profiles: Array(sharedProfiles.values),
                        message: "Restarting hop with updated SSH diagnostics",
                        options: options,
                        delay: 0,
                        origin: .userInitiated
                    )
                    stopManagedHopLocked(for: profile.id, updateStatus: false, reason: .replacement)
                    return
                }
                current.profiles[profile.id] = profile
                updateStatusLocked(
                    profile.id,
                    jumpHost: current.controlMaster.jumpHost,
                    statuses[current.profile.id]?.health ?? .connecting,
                    "Reusing shared hop ControlMaster",
                    pid: current.session.processIdentifier,
                    ownership: current.ownership
                )
                return
            }

            if let shared = processes.values.first(where: { $0.controlMaster.endpoint == controlMaster.endpoint && $0.session.isRunning }) {
                guard shared.controlMaster.signature == controlMaster.signature else {
                    throw HopControlMasterError.incompatibleConfiguration(endpoint: controlMaster.endpoint)
                }
                shared.profiles[profile.id] = profile
                processes[profile.id] = shared
                let sharedHealth = statuses[shared.profile.id]?.health ?? .connecting
                updateStatusLocked(
                    profile.id,
                    jumpHost: shared.controlMaster.jumpHost,
                    sharedHealth,
                    "Sharing hop ControlMaster with \(shared.profile.name)",
                    pid: shared.session.processIdentifier,
                    ownership: shared.ownership
                )
                return
            }

            if processes[profile.id] != nil {
                stopLocked(profileID: profile.id, updateStatus: false, reason: .replacement)
            }
            let launchHealth: TunnelHealth = origin == .automatic ? .reconnecting : .connecting
            updateStatusLocked(profile.id, jumpHost: controlMaster.jumpHost, launchHealth, message, pid: nil)
            let preparation = try ownershipManager.prepare(controlMaster)
            let managed: ManagedHopConnection
            if let adoptedPID = preparation.adoptedPID {
                managed = ManagedHopConnection(
                    profile: profile,
                    controlMaster: controlMaster,
                    credentials: HopCredentials(password: nil, totp: nil),
                    launchOptions: options,
                    startedAt: now()
                )
                managed.session = AdoptedSSHProcessSession(pid: adoptedPID, controlMaster: controlMaster)
            } else {
                let credentials = try credentials(for: profile)
                try runKerberosSwitchIfNeeded(profile: profile)
                let endpoint = SSHConnectionEndpoint(hopEndpoint: controlMaster.endpoint)
                let reservation = try automaticAttemptReservationIfNeeded(origin: origin, endpoint: endpoint)
                do {
                    managed = try launch(profile: profile, controlMaster: controlMaster, credentials: credentials, options: options)
                } catch {
                    if let reservation {
                        attemptLedger.cancel(reservation)
                    }
                    throw error
                }
                if origin == .userInitiated {
                    attemptLedger.recordUserInitiatedAttempt(to: endpoint, at: now())
                }
                do {
                    try ownershipManager.recordLaunch(controlMaster, sessionPID: managed.session.processIdentifier)
                } catch {
                    managed.session.terminate()
                    ownershipManager.cleanup(controlMaster, sessionPID: managed.session.processIdentifier)
                    throw error
                }
            }
            managed.ownershipLease = preparation.lease
            managed.ownership = preparation.ownership
            attachPendingSharedProfiles(to: managed, primaryProfile: profile)
            let startedMessage: String
            if origin == .automatic {
                let attempt = reconnectAttempts[profile.id] ?? 1
                let sharedProfiles = Array(managed.profiles.values)
                let limit = sharedProfiles
                    .filter(\.autoReconnect)
                    .map { TunnelLifecyclePolicy.effectiveReconnectAttemptLimit($0.curatedSSHOptions.maxReconnectAttempts) }
                    .min() ?? TunnelLifecyclePolicy.maximumReconnectAttempts
                startedMessage = "Automatic hop reconnect attempt \(attempt) of \(limit) started"
            } else {
                startedMessage = preparation.adoptedPID == nil
                    ? "SSH hop process started"
                    : "Adopted existing SSH AutoTunnel hop master"
            }
            updateManagedStatusLocked(
                managed,
                launchHealth,
                startedMessage,
                pid: managed.session.processIdentifier
            )
        } catch {
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            pendingReconnects[profile.id] = nil
            pendingSharedProfiles[profile.id] = nil
            let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let issue = (error as? HopControlMasterError)?.issue
            let message = origin == .automatic
                ? "\(error.localizedDescription) Automatic hop reconnect stopped; no further automatic attempts will occur."
                : "\(error.localizedDescription) No automatic retry will be attempted."
            updateStatusLocked(profile.id, jumpHost: jumpHost, .failed, message, pid: nil, issue: issue)
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

    private func attachPendingSharedProfiles(to managed: ManagedHopConnection, primaryProfile: TunnelProfile) {
        let sharedProfiles = pendingSharedProfiles.removeValue(forKey: primaryProfile.id) ?? [primaryProfile]
        for shared in sharedProfiles {
            managed.profiles[shared.id] = shared
            processes[shared.id] = managed
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

    private func launch(profile: TunnelProfile, controlMaster: JumpHostControlMaster, credentials: HopCredentials, options: SSHLaunchOptions) throws -> ManagedHopConnection {
        let managed = ManagedHopConnection(profile: profile, controlMaster: controlMaster, credentials: credentials, launchOptions: options, startedAt: now())
        managed.session = try processLauncher.launch(
            command: controlMaster.command,
            terminalFileDescriptor: nil,
            onOutput: { [weak self, weak managed] data in
                guard let managed else { return }
                self?.queue.async {
                    self?.handleOutput(data, hop: managed)
                }
            },
            onTermination: { [weak self, weak managed] session in
                self?.queue.async {
                    guard let self, let managed else { return }
                    self.observeProcessTerminationLocked(managed, terminationStatus: session.terminationStatus)
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
            for id in hop.profiles.keys {
                reconnectTokens[id] = nil
                reconnectAttempts[id] = nil
            }
            logEventLocked("existing hop session detected; stopping auto-reconnect", profileID: hop.profile.id)
            let failureMessage = Self.existingSessionFailureMessage(for: hop.controlMaster.jumpHost)
            let issue = HopConnectionIssue(
                code: .serverExistingSession,
                summary: "The hop server rejected another session",
                detail: failureMessage,
                recoverySuggestion: "Close the independent hop session or reconnect it through SSH AutoTunnel's shared adapter.",
                retryable: true
            )
            updateManagedStatusLocked(
                hop,
                .failed,
                failureMessage,
                pid: hop.session.processIdentifier,
                issue: issue
            )
            stopManagedHopLocked(for: hop.profile.id, updateStatus: false, reason: .user)
            return
        }
    }

    private static func existingSessionFailureMessage(for jumpHost: String) -> String {
        "SSH hop failed: an existing hop session is already active on \(jumpHost). Close that session and retry. No further automatic attempts will occur."
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
                updateManagedStatusLocked(
                    hop,
                    .failed,
                    "SSH host key prompt blocked by \(hop.profile.hostKeyPolicy.displayName) policy. No further automatic attempts will occur.",
                    pid: hop.session.processIdentifier
                )
                stopManagedHopLocked(for: hop.profile.id, updateStatus: false, reason: .user)
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
                    updateManagedStatusLocked(
                        hop,
                        .failed,
                        "Could not generate TOTP: \(error.localizedDescription). No further automatic attempts will occur.",
                        pid: hop.session.processIdentifier
                    )
                    stopManagedHopLocked(for: hop.profile.id, updateStatus: false, reason: .user)
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
        guard let managed = processes[profileID] else {
            if updateStatus {
                if let stopping = terminatingProcesses.values.first(where: { $0.profile.id == profileID }) {
                    updateStatusLocked(
                        profileID,
                        jumpHost: stopping.controlMaster.jumpHost,
                        .stopping,
                        "Stopping SSH hop process",
                        pid: stopping.session.processIdentifier
                    )
                } else {
                    let existing = statuses[profileID]
                    updateStatusLocked(profileID, jumpHost: existing?.jumpHost ?? "", .stopped, "Stopped", pid: nil)
                }
            }
            return
        }
        processes[profileID] = nil
        if managed.profiles.count > 1 {
            managed.profiles[profileID] = nil
            if updateStatus {
                updateStatusLocked(
                    profileID,
                    jumpHost: managed.controlMaster.jumpHost,
                    .stopped,
                    "Stopped using shared hop; ControlMaster remains active for other profiles",
                    pid: nil
                )
            }
            return
        }
        terminateManagedHopLocked(managed, updateStatus: updateStatus, reason: reason)
    }

    private func stopManagedHopLocked(for profileID: UUID, updateStatus: Bool, reason: ManagedHopConnection.StopReason) {
        guard let managed = processes[profileID] else {
            stopLocked(profileID: profileID, updateStatus: updateStatus, reason: reason)
            return
        }
        for id in managed.profiles.keys {
            processes[id] = nil
        }
        terminateManagedHopLocked(managed, updateStatus: updateStatus, reason: reason)
    }

    private func terminateManagedHopLocked(
        _ managed: ManagedHopConnection,
        updateStatus: Bool,
        reason: ManagedHopConnection.StopReason
    ) {
        flushRedactedOutputLocked(managed)
        managed.stopReason = reason
        managed.stopUpdatesStatus = updateStatus
        if managed.session.isRunning {
            terminatingProcesses[managed.session.processIdentifier] = managed
            logEventLocked("termination requested; sending SIGTERM to pid \(managed.session.processIdentifier)", profileID: managed.profile.id)
            if updateStatus {
                updateManagedStatusLocked(managed, .stopping, "Stopping SSH hop process", pid: managed.session.processIdentifier)
            }
            managed.session.terminate()
            if !managed.session.isRunning {
                observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
            }
            queue.asyncAfter(deadline: .now() + stopForceKillDelay) { [weak self, managed] in
                self?.forceKillIfStillStoppingLocked(managed)
            }
        } else {
            terminatingProcesses[managed.session.processIdentifier] = managed
            observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
        }
    }

    private func forceKillIfStillStoppingLocked(_ managed: ManagedHopConnection) {
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

    private func verifyStoppedAfterForceKillLocked(_ managed: ManagedHopConnection) {
        guard terminatingProcesses[managed.session.processIdentifier] === managed else { return }
        guard managed.session.isRunning else {
            observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
            return
        }
        if managed.stopUpdatesStatus {
            updateStatusLocked(
                managed.profile.id,
                jumpHost: managed.controlMaster.jumpHost,
                .failed,
                "Could not stop SSH hop process after SIGKILL",
                pid: managed.session.processIdentifier
            )
        }
    }

    private func observeProcessTerminationLocked(_ managed: ManagedHopConnection, terminationStatus: Int32) {
        guard isTrackedLocked(managed) else { return }
        guard managed.observedTerminationStatus == nil else { return }

        managed.observedTerminationStatus = terminationStatus
        flushRedactedOutputLocked(managed)

        let finalize = { [weak self, weak managed] in
            guard let self, let managed else { return }
            self.finalizeProcessTerminationLocked(managed)
        }

        if processExitObservationDelay <= 0 {
            finalize()
        } else {
            queue.asyncAfter(deadline: .now() + processExitObservationDelay, execute: finalize)
        }
    }

    private func finalizeProcessTerminationLocked(_ managed: ManagedHopConnection) {
        guard isTrackedLocked(managed),
              let terminationStatus = managed.observedTerminationStatus else {
            return
        }

        flushRedactedOutputLocked(managed)
        let wasTerminating = terminatingProcesses[managed.session.processIdentifier] === managed
        for id in managed.profiles.keys where processes[id] === managed {
            processes[id] = nil
        }
        if wasTerminating {
            terminatingProcesses[managed.session.processIdentifier] = nil
        }
        ownershipManager.cleanup(managed.controlMaster, sessionPID: managed.session.processIdentifier)
        managed.ownershipLease = nil

        if wasTerminating {
            if managed.stopUpdatesStatus {
                updateManagedStatusLocked(managed, .stopped, "Stopped", pid: nil)
            }
            if let pendingStart = managed.pendingStart {
                pendingSharedProfiles[pendingStart.profile.id] = pendingStart.profiles
                switch pendingStart.origin {
                case .userInitiated:
                    scheduleUserInitiatedStartLocked(
                        profile: pendingStart.profile,
                        message: pendingStart.message,
                        delay: pendingStart.delay ?? 0,
                        options: pendingStart.options
                    )
                case .automatic:
                    scheduleReconnectLocked(
                        profile: pendingStart.profile,
                        message: pendingStart.message,
                        delay: pendingStart.delay,
                        options: pendingStart.options
                    )
                }
            }
            return
        }

        let hasExistingSessionConflict = managed.hasExistingSessionConflict || managed.matchesExistingSessionConflict
        let campaignIsActive = (reconnectAttempts[managed.profile.id] ?? 0) > 0
        let failureDisposition = SSHConnectionFailureClassifier.disposition(
            transcript: managed.redactedTranscript,
            reachedHealthyState: managed.reachedHealthy
        )
        let decision = hasExistingSessionConflict
            ? TunnelLifecyclePolicy.ProcessExitDecision.markFailed
            : TunnelLifecyclePolicy.processExitDecision(
                terminationStatus: terminationStatus,
                wasIntentionalStop: managed.stopReason != nil,
                autoReconnect: managed.profiles.values.contains(where: \.autoReconnect),
                canAutomaticallyReconnect: managed.reachedHealthy || campaignIsActive,
                failureIsRetryable: failureDisposition == .retryable
            )
        var exitDetail = managed.lastOutputLine
        if failureDisposition == .terminal, managed.stopReason == nil {
            let detail = exitDetail.map { "\($0); " } ?? ""
            exitDetail = "\(detail)authentication or host-key failure is not retryable; automatic reconnect stopped and no more attempts will be made"
        } else if !managed.reachedHealthy, !campaignIsActive, managed.stopReason == nil,
                  managed.profiles.values.contains(where: \.autoReconnect) {
            let detail = exitDetail.map { "\($0); " } ?? ""
            exitDetail = "\(detail)automatic reconnect was not started because this hop never became healthy"
        } else if decision == .markFailed, managed.stopReason == nil {
            let detail = exitDetail.map { "\($0); " } ?? ""
            exitDetail = "\(detail)automatic hop reconnect is disabled or this failure is not retryable; no further automatic attempts will occur"
        }
        applyProcessExitDecisionLocked(
            decision,
            managed: managed,
            terminationStatus: terminationStatus,
            exitDetail: exitDetail,
            forcedFailureMessage: hasExistingSessionConflict
                ? Self.existingSessionFailureMessage(for: managed.controlMaster.jumpHost)
                : nil
        )
    }

    private func isTrackedLocked(_ managed: ManagedHopConnection) -> Bool {
        processes.values.contains(where: { $0 === managed })
            || terminatingProcesses[managed.session.processIdentifier] === managed
    }

    private func applyProcessExitDecisionLocked(
        _ decision: TunnelLifecyclePolicy.ProcessExitDecision,
        managed: ManagedHopConnection,
        terminationStatus: Int32,
        exitDetail: String?,
        forcedFailureMessage: String? = nil
    ) {
        switch decision {
        case .ignore:
            return
        case .markStopped:
            for id in managed.profiles.keys {
                reconnectTokens[id] = nil
                reconnectAttempts[id] = nil
                removePendingReconnectLocked(containing: id)
            }
            updateManagedStatusLocked(managed, .stopped, sshExitMessage(status: terminationStatus, detail: exitDetail), pid: nil)
        case .markFailed:
            for id in managed.profiles.keys {
                reconnectTokens[id] = nil
                reconnectAttempts[id] = nil
                removePendingReconnectLocked(containing: id)
            }
            let issue: HopConnectionIssue? = forcedFailureMessage.map {
                HopConnectionIssue(
                    code: .serverExistingSession,
                    summary: "The hop server rejected another session",
                    detail: $0,
                    recoverySuggestion: "Close the independent hop session or reconnect it through SSH AutoTunnel's shared adapter.",
                    retryable: true
                )
            }
            updateManagedStatusLocked(
                managed,
                .failed,
                forcedFailureMessage ?? sshExitMessage(status: terminationStatus, detail: exitDetail),
                pid: nil,
                issue: issue
            )
        case .reconnect:
            let profiles = Array(managed.profiles.values)
            let profile = profiles.first(where: { $0.id == managed.profile.id }) ?? managed.profile
            pendingSharedProfiles[profile.id] = profiles
            for shared in profiles where shared.id != profile.id {
                updateStatusLocked(
                    shared.id,
                    jumpHost: managed.controlMaster.jumpHost,
                    .reconnecting,
                    "\(sshExitMessage(status: terminationStatus, detail: exitDetail)); reconnecting shared hop",
                    pid: nil,
                    ownership: managed.ownership
                )
            }
            scheduleReconnectLocked(
                profile: profile,
                message: "\(sshExitMessage(status: terminationStatus, detail: exitDetail)); reconnecting hop",
                options: managed.launchOptions
            )
        }
    }

    private func sshExitMessage(status: Int32, detail: String?) -> String {
        guard let detail, !detail.isEmpty else {
            return "SSH hop exited with status \(status)"
        }
        return "SSH hop exited with status \(status): \(detail)"
    }

    private func scheduleUserInitiatedStartLocked(
        profile: TunnelProfile,
        message: String,
        delay: TimeInterval,
        options: SSHLaunchOptions
    ) {
        let token = UUID()
        reconnectTokens[profile.id] = token
        let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? statuses[profile.id]?.jumpHost ?? ""
        updateStatusLocked(profile.id, jumpHost: jumpHost, .reconnecting, message, pid: nil)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.reconnectTokens[profile.id] == token else { return }
            self.reconnectTokens[profile.id] = nil
            self.startLocked(profile: profile, message: message, options: options, origin: .userInitiated)
        }
    }

    private func scheduleReconnectLocked(profile: TunnelProfile, message: String, delay explicitDelay: TimeInterval? = nil, options: SSHLaunchOptions) {
        let attempt = (reconnectAttempts[profile.id] ?? 0) + 1
        let sharedProfiles = pendingSharedProfiles[profile.id] ?? [profile]
        let limit = sharedProfiles
            .filter(\.autoReconnect)
            .map { TunnelLifecyclePolicy.effectiveReconnectAttemptLimit($0.curatedSSHOptions.maxReconnectAttempts) }
            .min() ?? 0
        if attempt > limit {
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            pendingReconnects[profile.id] = nil
            pendingSharedProfiles[profile.id] = nil
            let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? statuses[profile.id]?.jumpHost ?? ""
            updateStatusLocked(
                profile.id,
                jumpHost: jumpHost,
                .failed,
                "Automatic hop reconnect stopped after \(limit) failed attempts; no more automatic attempts will be made",
                pid: nil
            )
            logEventLocked("automatic hop reconnect stopped after \(limit) failed attempts", profileID: profile.id)
            return
        }
        reconnectAttempts[profile.id] = attempt
        let delay = explicitDelay ?? reconnectDelay(attempt)
        pendingReconnects[profile.id] = PendingHopReconnect(
            profile: profile,
            sharedProfiles: sharedProfiles,
            message: message,
            options: options,
            attempt: attempt,
            limit: limit,
            eligibleAt: now().addingTimeInterval(delay)
        )
        logEventLocked("reconnect attempt \(attempt) scheduled in \(String(format: "%.1f", delay))s", profileID: profile.id)
        armPendingReconnectLocked(profileID: profile.id)
    }

    private func removePendingReconnectLocked(containing profileID: UUID) {
        let reconnectPrimaryIDs = pendingReconnects.compactMap { primaryID, pending in
            pending.sharedProfiles.contains(where: { $0.id == profileID }) ? primaryID : nil
        }
        let sharedPrimaryIDs = pendingSharedProfiles.compactMap { primaryID, profiles in
            profiles.contains(where: { $0.id == profileID }) ? primaryID : nil
        }
        let primaryIDs = Set(reconnectPrimaryIDs).union(sharedPrimaryIDs)
        for primaryID in primaryIDs {
            pendingReconnects[primaryID] = nil
            pendingSharedProfiles[primaryID] = nil
            reconnectTokens[primaryID] = nil
        }
    }

    private func pausePendingReconnectsLocked() {
        for primaryID in pendingReconnects.keys {
            reconnectTokens[primaryID] = nil
            updatePendingReconnectStatusesLocked(
                primaryID: primaryID,
                message: "Waiting for network; no SSH attempt will be made."
            )
            logEventLocked("automatic hop reconnect paused while waiting for a usable network path", profileID: primaryID)
        }
    }

    private func resumePendingReconnectsLocked() {
        for primaryID in pendingReconnects.keys {
            armPendingReconnectLocked(profileID: primaryID)
        }
    }

    private func armPendingReconnectLocked(profileID: UUID) {
        guard let pending = pendingReconnects[profileID] else { return }
        guard networkPathState.permitsSSHLaunch else {
            reconnectTokens[profileID] = nil
            updatePendingReconnectStatusesLocked(
                primaryID: profileID,
                message: "Waiting for network; no SSH attempt will be made."
            )
            return
        }

        let remainingDelay = max(0, pending.eligibleAt.timeIntervalSince(now()))
        let token = UUID()
        reconnectTokens[profileID] = token
        updatePendingReconnectStatusesLocked(
            primaryID: profileID,
            message: "\(pending.message); retry \(pending.attempt) of \(pending.limit) in \(Self.retryDelayDescription(remainingDelay))"
        )

        queue.asyncAfter(deadline: .now() + remainingDelay) { [weak self] in
            guard let self,
                  self.reconnectTokens[profileID] == token,
                  let pending = self.pendingReconnects[profileID],
                  self.networkPathState.permitsSSHLaunch else {
                return
            }
            self.reconnectTokens[profileID] = nil
            self.pendingReconnects[profileID] = nil
            self.pendingSharedProfiles[profileID] = pending.sharedProfiles
            self.startLocked(
                profile: pending.profile,
                message: "Reconnecting hop",
                options: pending.options,
                origin: .automatic
            )
        }
    }

    private func updatePendingReconnectStatusesLocked(primaryID: UUID, message: String) {
        guard let pending = pendingReconnects[primaryID] else { return }
        let jumpHost = pending.profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? statuses[primaryID]?.jumpHost
            ?? ""
        for shared in pending.sharedProfiles {
            updateStatusLocked(shared.id, jumpHost: jumpHost, .reconnecting, message, pid: nil)
        }
    }

    private static func retryDelayDescription(_ delay: TimeInterval) -> String {
        if delay < 10 { return "\(Int(ceil(delay))) seconds" }
        if delay < 60 { return "\(Int(round(delay))) seconds" }
        let minutes = Int(round(delay / 60))
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    private func updateManagedStatusLocked(
        _ managed: ManagedHopConnection,
        _ health: TunnelHealth,
        _ message: String,
        pid: Int32?,
        issue: HopConnectionIssue? = nil
    ) {
        for profileID in managed.profiles.keys {
            updateStatusLocked(
                profileID,
                jumpHost: managed.controlMaster.jumpHost,
                health,
                message,
                pid: pid,
                ownership: managed.ownership,
                issue: issue
            )
        }
    }

    private func updateStatusLocked(
        _ profileID: UUID,
        jumpHost: String,
        _ health: TunnelHealth,
        _ message: String,
        pid: Int32?,
        ownership: HopMasterOwnership? = nil,
        issue: HopConnectionIssue? = nil
    ) {
        let previous = statuses[profileID]
        let status = HopRuntimeStatus(
            profileID: profileID,
            jumpHost: jumpHost,
            health: health,
            message: message,
            pid: pid,
            ownership: ownership,
            issue: issue
        )
        statuses[profileID] = status
        if previous?.jumpHost != jumpHost || previous?.health != health || previous?.message != message
            || previous?.pid != pid || previous?.ownership != ownership || previous?.issue != issue {
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
        finalizeExitedTerminatingProcessesLocked()
        var seen: Set<ObjectIdentifier> = []
        let managedHops = processes.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
        for managed in managedHops {
            let profileID = managed.profile.id
            guard managed.session.isRunning else {
                observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
                continue
            }

            if healthCheck(managed.controlMaster), isReady(managed.controlMaster) {
                if !managed.didRecordReadyOwnership {
                    do {
                        try ownershipManager.recordReady(managed.controlMaster, sessionPID: managed.session.processIdentifier)
                        managed.didRecordReadyOwnership = true
                    } catch {
                        let issue = (error as? HopControlMasterError)?.issue
                        updateManagedStatusLocked(managed, .failed, error.localizedDescription, pid: managed.session.processIdentifier, issue: issue)
                        stopManagedHopLocked(for: profileID, updateStatus: false, reason: .user)
                        continue
                    }
                }
                if managed.profiles.keys.contains(where: { statuses[$0]?.health != .healthy }) {
                    updateManagedStatusLocked(managed, .healthy, "Jump host ControlMaster is ready", pid: managed.session.processIdentifier)
                }
                if !managed.reachedHealthy {
                    managed.reachedHealthy = true
                    managed.healthySince = now()
                }
                if let healthySince = managed.healthySince,
                   now().timeIntervalSince(healthySince) >= healthyResetInterval {
                    for id in managed.profiles.keys {
                        reconnectAttempts[id] = 0
                    }
                }
            } else {
                let hasInitialReadinessGraceExpired = now().timeIntervalSince(managed.startedAt) >= initialReadinessGracePeriod
                let campaignIsActive = (reconnectAttempts[profileID] ?? 0) > 0
                if hasInitialReadinessGraceExpired, !managed.reachedHealthy, !campaignIsActive {
                    stopManagedHopLocked(for: profileID, updateStatus: false, reason: .user)
                    updateManagedStatusLocked(
                        managed,
                        .failed,
                        "Initial SSH hop connection did not become healthy; automatic reconnect was not started",
                        pid: nil
                    )
                    continue
                }
                let decision = TunnelLifecyclePolicy.healthProbeFailureDecision(
                    previousHealth: statuses[profileID]?.health,
                    autoReconnect: managed.profiles.values.contains(where: \.autoReconnect)
                        && (managed.reachedHealthy || campaignIsActive),
                    hasInitialReadinessGraceExpired: hasInitialReadinessGraceExpired
                )
                switch decision {
                case .waitForInitialReadiness:
                    let message = JumpHostControlMasterFactory.requiresReadyMarker(for: managed.controlMaster.jumpHost)
                        ? "Waiting for SSH authentication and jump host setup prompt"
                        : "Waiting for SSH authentication and ControlMaster"
                    updateManagedStatusLocked(
                        managed,
                        statuses[profileID]?.health == .reconnecting ? .reconnecting : .connecting,
                        message,
                        pid: managed.session.processIdentifier
                    )
                case .markUnhealthy:
                    updateManagedStatusLocked(managed, .unhealthy, "Jump host ControlMaster check failed", pid: managed.session.processIdentifier)
                case .reconnect:
                    let sharedProfiles = Array(managed.profiles.values)
                    managed.pendingStart = .init(
                        profile: managed.profile,
                        profiles: sharedProfiles,
                        message: "Jump host ControlMaster check failed; reconnecting hop",
                        options: managed.launchOptions,
                        delay: nil,
                        origin: .automatic
                    )
                    stopManagedHopLocked(for: profileID, updateStatus: false, reason: .restart)
                }
            }
        }
    }

    private func finalizeExitedTerminatingProcessesLocked() {
        for managed in Array(terminatingProcesses.values) where !managed.session.isRunning {
            observeProcessTerminationLocked(managed, terminationStatus: managed.session.terminationStatus)
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

private struct PendingHopReconnect {
    var profile: TunnelProfile
    var sharedProfiles: [TunnelProfile]
    var message: String
    var options: SSHLaunchOptions
    var attempt: Int
    var limit: Int
    var eligibleAt: Date
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
    struct PendingStart {
        var profile: TunnelProfile
        var profiles: [TunnelProfile]
        var message: String
        var options: SSHLaunchOptions
        var delay: TimeInterval?
        var origin: SSHConnectionLaunchOrigin
    }

    enum StopReason {
        case user
        case restart
        case replacement
    }

    let profile: TunnelProfile
    var profiles: [UUID: TunnelProfile]
    let controlMaster: JumpHostControlMaster
    let credentials: HopCredentials
    let launchOptions: SSHLaunchOptions
    let startedAt: Date
    let readinessMarker: JumpHostReadinessMarker?
    var session: SSHProcessSession!
    var ownershipLease: HopControlMasterLease?
    var ownership: HopMasterOwnership = .appOwned
    var pendingStart: PendingStart?
    var didRecordReadyOwnership = false
    var outputBuffer = Data()
    var redactedSecrets: [String]
    var redactor: SSHTranscriptRedactor
    var stopReason: StopReason?
    var stopUpdatesStatus = false
    var observedTerminationStatus: Int32?
    var reachedHealthy = false
    var healthySince: Date?
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

    init(profile: TunnelProfile, controlMaster: JumpHostControlMaster, credentials: HopCredentials, launchOptions: SSHLaunchOptions, startedAt: Date) {
        self.profile = profile
        profiles = [profile.id: profile]
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
