import Darwin
import Foundation

public final class TunnelManager {
    public var onStatusChange: ((TunnelRuntimeStatus) -> Void)?
    public var onLog: ((UUID, String) -> Void)?

    private let keychain: KeychainService
    private let queue = DispatchQueue(label: "dev.clange.ssh-autotunnel.tunnels")
    private var processes: [UUID: ManagedTunnel] = [:]
    private var statuses: [UUID: TunnelRuntimeStatus] = [:]
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
            self.stopLocked(profileID: profile.id, updateStatus: false)
            self.updateStatusLocked(profile.id, .connecting, "Starting tunnel", pid: nil)
            do {
                let credentials = try self.credentials(for: profile)
                try self.runKerberosSwitchIfNeeded(profile: profile)
                let managed = try self.launch(profile: profile, credentials: credentials)
                self.processes[profile.id] = managed
                self.updateStatusLocked(profile.id, .connecting, "SSH process started", pid: managed.process.processIdentifier)
            } catch {
                self.updateStatusLocked(profile.id, .failed, error.localizedDescription, pid: nil)
            }
        }
    }

    public func stop(profileID: UUID) {
        queue.async {
            self.stopLocked(profileID: profileID, updateStatus: true)
        }
    }

    public func stopAll() {
        queue.sync {
            for profileID in processes.keys {
                stopLocked(profileID: profileID, updateStatus: true)
            }
        }
    }

    public func reconnect(profile: TunnelProfile) {
        queue.async {
            self.stopLocked(profileID: profile.id, updateStatus: false)
            self.updateStatusLocked(profile.id, .reconnecting, "Reconnecting", pid: nil)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.start(profile: profile)
            }
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
        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                self?.processes[profile.id] = nil
                let health: TunnelHealth = process.terminationStatus == 0 ? .stopped : .failed
                self?.updateStatusLocked(profile.id, health, "SSH exited with status \(process.terminationStatus)", pid: nil)
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

    private func stopLocked(profileID: UUID, updateStatus: Bool) {
        guard let managed = processes.removeValue(forKey: profileID) else {
            if updateStatus {
                updateStatusLocked(profileID, .stopped, "Stopped", pid: nil)
            }
            return
        }
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
        for (profileID, managed) in processes {
            guard managed.process.isRunning else {
                updateStatusLocked(profileID, .failed, "SSH process is not running", pid: nil)
                processes[profileID] = nil
                continue
            }

            if isPortOpen(port: managed.profile.localSocksPort) {
                let current = statuses[profileID]?.health
                if current != .healthy {
                    updateStatusLocked(profileID, .healthy, "SOCKS port is accepting connections", pid: managed.process.processIdentifier)
                }
            } else {
                updateStatusLocked(profileID, .unhealthy, "SOCKS port is not reachable", pid: managed.process.processIdentifier)
            }
        }
    }

    private func isPortOpen(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

private struct TunnelCredentials {
    var password: String?
    var totp: String?
}

private final class ManagedTunnel {
    let profile: TunnelProfile
    let process: Process
    let master: FileHandle
    let credentials: TunnelCredentials
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
