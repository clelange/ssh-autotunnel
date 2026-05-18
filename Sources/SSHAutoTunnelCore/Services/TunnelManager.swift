import Darwin
import Foundation

public final class TunnelManager {
    public var onStatusChange: ((TunnelRuntimeStatus) -> Void)?
    public var onLog: ((UUID, String) -> Void)?

    private let keychain: KeychainService
    private let queue = DispatchQueue(label: "dev.clange.ssh-autotunnel.tunnels")
    private var processes: [UUID: ManagedTunnel] = [:]
    private var statuses: [UUID: TunnelRuntimeStatus] = [:]
    private var reconnectTokens: [UUID: UUID] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var healthTimer: DispatchSourceTimer?

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
        startHealthTimer()
    }

    deinit {
        stopAll()
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
            updateStatusLocked(profile.id, .connecting, "SSH process started", pid: managed.process.processIdentifier)
        } catch {
            updateStatusLocked(profile.id, .failed, error.localizedDescription, pid: nil)
        }
    }

    private func credentials(for profile: TunnelProfile) throws -> TunnelCredentials {
        var password: String?
        var totp: String?

        if profile.authMode == .password || profile.authMode == .passwordAndTOTP {
            guard let service = profile.keychain.passwordService else {
                throw NSError(domain: "TunnelManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Password service is not configured"])
            }
            password = try keychain.readGenericPassword(service: service, account: profile.keychain.account)
        }

        if profile.authMode == .totp || profile.authMode == .passwordAndTOTP || profile.authMode == .kerberosAndTOTP {
            guard let service = profile.keychain.totpService else {
                throw NSError(domain: "TunnelManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "TOTP service is not configured"])
            }
            let seed = try keychain.readGenericPassword(service: service, account: profile.keychain.account)
            totp = try TOTPGenerator.generate(secretBase32: seed)
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
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not allocate pseudo-terminal"])
        }

        let process = Process()
        let command = SSHCommandBuilder.tunnelCommand(for: profile)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        process.standardOutput = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        process.standardError = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        close(slave)

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let managed = ManagedTunnel(profile: profile, process: process, master: masterHandle, credentials: credentials)
        process.terminationHandler = { [weak self, weak managed] process in
            self?.queue.async {
                guard let self, let managed else { return }
                guard self.processes[profile.id] === managed else { return }
                self.processes[profile.id] = nil

                let decision = TunnelLifecyclePolicy.processExitDecision(
                    terminationStatus: process.terminationStatus,
                    wasIntentionalStop: managed.stopReason != nil,
                    autoReconnect: profile.autoReconnect
                )
                self.applyProcessExitDecisionLocked(decision, profile: profile, terminationStatus: process.terminationStatus)
            }
        }

        try process.run()
        readLoop(managed)
        return managed
    }

    private func readLoop(_ managed: ManagedTunnel) {
        DispatchQueue.global(qos: .utility).async { [weak self, weak managed] in
            guard let managed else { return }
            var buffer = Data()
            while managed.process.isRunning {
                let data = managed.master.availableData
                if data.isEmpty { break }
                buffer.append(data)
                let text = String(data: data, encoding: .utf8) ?? ""
                self?.onLog?(managed.profile.id, text)
                self?.respondIfNeeded(to: buffer, tunnel: managed)
                if buffer.count > 4096 {
                    buffer.removeFirst(buffer.count - 2048)
                }
            }
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
            tunnel.sentHostKeyConfirmation = true
            write("yes\n", to: tunnel)
        case .sendPassword:
            guard !tunnel.sentPassword else { return }
            if let password = tunnel.credentials.password {
                tunnel.sentPassword = true
                write(password + "\n", to: tunnel)
            }
        case .sendTOTP:
            guard !tunnel.sentTOTP else { return }
            if let totp = tunnel.credentials.totp {
                tunnel.sentTOTP = true
                write(totp + "\n", to: tunnel)
            }
        }
    }

    private func write(_ string: String, to tunnel: ManagedTunnel) {
        if let data = string.data(using: .utf8) {
            tunnel.master.write(data)
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
        if managed.process.isRunning {
            managed.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if managed.process.isRunning {
                    kill(managed.process.processIdentifier, SIGKILL)
                }
            }
        }
        if updateStatus {
            updateStatusLocked(profileID, .stopped, "Stopped", pid: nil)
        }
    }

    private func applyProcessExitDecisionLocked(_ decision: TunnelLifecyclePolicy.ProcessExitDecision, profile: TunnelProfile, terminationStatus: Int32) {
        switch decision {
        case .ignore:
            return
        case .markStopped:
            reconnectTokens[profile.id] = nil
            reconnectAttempts[profile.id] = nil
            updateStatusLocked(profile.id, .stopped, "SSH exited with status \(terminationStatus)", pid: nil)
        case .markFailed:
            reconnectTokens[profile.id] = nil
            updateStatusLocked(profile.id, .failed, "SSH exited with status \(terminationStatus)", pid: nil)
        case .reconnect:
            scheduleReconnectLocked(profile: profile, message: "SSH exited with status \(terminationStatus); reconnecting")
        }
    }

    private func scheduleReconnectLocked(profile: TunnelProfile, message: String, delay explicitDelay: TimeInterval? = nil) {
        let attempt = (reconnectAttempts[profile.id] ?? 0) + 1
        reconnectAttempts[profile.id] = attempt
        let delay = explicitDelay ?? TunnelLifecyclePolicy.reconnectDelay(forAttempt: attempt)
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
            guard managed.process.isRunning else {
                processes[profileID] = nil
                let decision = TunnelLifecyclePolicy.processExitDecision(
                    terminationStatus: managed.process.terminationStatus,
                    wasIntentionalStop: managed.stopReason != nil,
                    autoReconnect: managed.profile.autoReconnect
                )
                applyProcessExitDecisionLocked(decision, profile: managed.profile, terminationStatus: managed.process.terminationStatus)
                continue
            }

            if SOCKS5Probe.probe(port: managed.profile.localSocksPort) {
                let current = statuses[profileID]?.health
                if current != .healthy {
                    updateStatusLocked(profileID, .healthy, "SOCKS5 handshake succeeded", pid: managed.process.processIdentifier)
                }
                reconnectAttempts[profileID] = 0
            } else {
                let decision = TunnelLifecyclePolicy.healthProbeFailureDecision(
                    previousHealth: statuses[profileID]?.health,
                    autoReconnect: managed.profile.autoReconnect
                )
                switch decision {
                case .markUnhealthy:
                    updateStatusLocked(profileID, .unhealthy, "SOCKS5 probe failed", pid: managed.process.processIdentifier)
                case .reconnect:
                    stopLocked(profileID: profileID, updateStatus: false, reason: .restart)
                    scheduleReconnectLocked(profile: managed.profile, message: "SOCKS5 probe failed; reconnecting")
                }
            }
        }
    }
}

private struct TunnelCredentials {
    var password: String?
    var totp: String?
}

private final class ManagedTunnel {
    enum StopReason {
        case user
        case restart
        case replacement
    }

    let profile: TunnelProfile
    let process: Process
    let master: FileHandle
    let credentials: TunnelCredentials
    var stopReason: StopReason?
    var sentHostKeyConfirmation = false
    var sentPassword = false
    var sentTOTP = false

    init(profile: TunnelProfile, process: Process, master: FileHandle, credentials: TunnelCredentials) {
        self.profile = profile
        self.process = process
        self.master = master
        self.credentials = credentials
    }
}
