import AppKit
import Foundation
import Network
import SSHAutoTunnelCore
import SwiftUI

struct ProfileDeletionResult {
    var profileCount: Int
    var requestedKeychainCleanup: Bool
    var deletedKeychainItemCount: Int
    var keychainCleanupError: Error?
}

enum ProfileCredentialAvailability: Equatable {
    case notConfigured
    case found
    case missing
    case unreadable(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var statuses: [UUID: TunnelRuntimeStatus] = [:]
    @Published var hopStatuses: [UUID: HopRuntimeStatus] = [:]
    @Published var logs: [UUID: String] = [:]
    @Published var networkDecision = NetworkPolicyDecision(shouldDisableProxy: false, matchedRule: nil)
    @Published var currentNetworkFingerprint = NetworkFingerprint()
    @Published var lastProxyMessage = "System PAC is not enabled"
    @Published var systemPACStatus = SystemPACStatus.unknown(expectedPACURL: "")
    @Published var configurationValidationMessage: String?
    @Published var sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus] = []
    @Published var pacAppendSourceMessage = "Existing PAC appending disabled"
    @Published var diagnosticsSelectedProfileID: UUID?
    @Published var interactiveTerminalInstallations: [InteractiveTerminalInstallation] = []

    private let configurationStore: ConfigurationStore
    private let tunnelManager = TunnelManager()
    private let hopManager = HopConnectionManager()
    private let keychain = KeychainService()
    private let networkIdentity = NetworkIdentityService()
    private let proxyManager = SystemProxyManager()
    private let notifications = AppNotificationService()
    private let sshLogStore = SSHLogStore()
    private let configurationArtifacts = AppConfigurationArtifactService()
    private let interactiveSessionRegistry = InteractiveSSHSessionRegistry()
    private let terminalLauncher = InteractiveTerminalLauncher()
    private let terminalDiscovery = InteractiveTerminalDiscovery()
    private var pathMonitor: NWPathMonitor?
    private var pendingConfigurationSaveTask: Task<Void, Never>?
    private var pendingPACAppendSourceTask: Task<Void, Never>?
    private var pendingTunnelStartTokens: [UUID: UUID] = [:]
    private var loadedPACAppendSource: PACAppendSource?
    private var appendedPACContent: String?
    private let jsonEncoder = JSONEncoder()
    private lazy var localServers = LocalServerCoordinator<LocalHTTPServer> { [weak self] role, port in
        guard let self else {
            throw NSError(domain: "AppState", code: 1, userInfo: [NSLocalizedDescriptionKey: "App state is unavailable"])
        }
        return try self.makeLocalServer(role: role, port: port)
    }

    init() {
        do {
            configurationStore = try ConfigurationStore()
            let loadResult = try configurationStore.loadRecovering()
            configuration = loadResult.configuration
            if loadResult.didRecover {
                if let backupPath = loadResult.backupURL?.path {
                    lastProxyMessage = "Recovered defaults after invalid config. Backup: \(backupPath)"
                } else {
                    lastProxyMessage = "Recovered defaults after invalid config"
                }
            }
        } catch {
            fatalError("Could not load configuration: \(error)")
        }

        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        setupNotificationCallbacks()
        setupHopCallbacks()
        setupTunnelCallbacks()
        refreshNetworkDecision()
        startServers()
        startNetworkMonitoring()
        refreshInteractiveTerminalDiscovery()
        refreshPACAppendSource(force: true)
        writePACCopy()
        refreshSystemPACStatus()
        connectLaunchProfiles()
    }

    var pacURL: String {
        "http://127.0.0.1:\(localServers.activePorts?.pacHTTPPort ?? configuration.pacHTTPPort)/proxy.pac?v=\(pacVersion)"
    }

    var statusURL: String {
        "http://127.0.0.1:\(localServers.activePorts?.pacHTTPPort ?? configuration.pacHTTPPort)/status"
    }

    var activeServerPorts: LocalServerPorts? {
        localServers.activePorts
    }

    private var pacVersion: Int {
        let statusHash = statuses.values
            .sorted { $0.profileID.uuidString < $1.profileID.uuidString }
            .map { status in
                let effectivePort = status.effectiveLocalSocksPort.map(String.init) ?? "-"
                return "\(status.profileID.uuidString):\(status.health.rawValue):\(effectivePort)"
            }
            .joined(separator: "|")
            .hashValue
        return abs(statusHash)
    }

    func status(for profile: TunnelProfile) -> TunnelRuntimeStatus {
        statuses[profile.id] ?? TunnelRuntimeStatus(profileID: profile.id)
    }

    func hopStatus(for profile: TunnelProfile) -> HopRuntimeStatus? {
        guard let jumpHost = normalizedJumpHost(for: profile) else { return nil }
        if let status = hopStatuses[profile.id], status.jumpHost == jumpHost {
            return status
        }
        return HopRuntimeStatus(profileID: profile.id, jumpHost: jumpHost)
    }

    func hasJumpHost(_ profile: TunnelProfile) -> Bool {
        normalizedJumpHost(for: profile) != nil
    }

    func connect(_ profile: TunnelProfile) {
        startSSHLogSession(for: profile, verbose: false)
        if hasJumpHost(profile) {
            let token = UUID()
            pendingTunnelStartTokens[profile.id] = token
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .connecting, message: "Waiting for hop connection")
            lastProxyMessage = "\(profile.name): Waiting for hop connection"
            Task {
                await connectTunnelThroughHop(profile, token: token, options: .standard)
            }
        } else {
            startTunnel(profile, message: "Starting tunnel", options: .standard)
        }
    }

    func disconnect(_ profile: TunnelProfile) {
        pendingTunnelStartTokens[profile.id] = nil
        lastProxyMessage = "\(profile.name): Disconnect requested"
        tunnelManager.stop(profileID: profile.id)
    }

    func reconnect(_ profile: TunnelProfile) {
        startSSHLogSession(for: profile, verbose: false)
        if hasJumpHost(profile) {
            let token = UUID()
            pendingTunnelStartTokens[profile.id] = token
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .reconnecting, message: "Reconnect requested; waiting for hop")
            lastProxyMessage = "\(profile.name): Reconnect requested; waiting for hop"
            tunnelManager.stop(profileID: profile.id)
            Task {
                await connectTunnelThroughHop(profile, token: token, options: .standard)
            }
        } else {
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .reconnecting, message: "Reconnect requested")
            lastProxyMessage = "\(profile.name): Reconnect requested"
            tunnelManager.reconnect(profile: profile, options: .standard, reservedSocksPorts: reservedSocksPorts(excluding: profile.id))
        }
    }

    func connectAll() {
        for profile in configuration.profiles where !isActive(status(for: profile).health) {
            connect(profile)
        }
    }

    func disconnectAll() {
        pendingTunnelStartTokens.removeAll()
        for profile in configuration.profiles {
            tunnelManager.stop(profileID: profile.id)
            if hasJumpHost(profile) {
                hopManager.stop(profileID: profile.id)
            }
        }
        lastProxyMessage = "Disconnect all requested"
    }

    func connectHop(_ profile: TunnelProfile) {
        startHop(profile, resetLog: true)
    }

    func disconnectHop(_ profile: TunnelProfile) {
        pendingTunnelStartTokens[profile.id] = nil
        lastProxyMessage = "\(profile.name): Hop disconnect requested"
        hopManager.stop(profileID: profile.id)
    }

    func reconnectHop(_ profile: TunnelProfile) {
        startSSHLogSession(for: profile, verbose: false)
        guard hasJumpHost(profile) else {
            lastProxyMessage = "\(profile.name): No jump host configured"
            return
        }
        hopStatuses[profile.id] = HopRuntimeStatus(
            profileID: profile.id,
            jumpHost: normalizedJumpHost(for: profile) ?? "",
            health: .reconnecting,
            message: "Reconnect requested"
        )
        lastProxyMessage = "\(profile.name): Hop reconnect requested"
        hopManager.reconnect(profile: profile, options: .standard)
    }

    func connectInteractiveSSH(_ profile: TunnelProfile) {
        do {
            let interactiveProfile = InteractiveSSHProfileResolver.resolve(profile: profile, in: configuration)
            if InteractiveSSHJumpHostPolicy.requiresPersistentJumpHostSession(interactiveProfile) {
                lastProxyMessage = "\(profile.name): Preparing hop for interactive SSH"
                Task {
                    await connectInteractiveSSHThroughHop(profile: profile, interactiveProfile: interactiveProfile)
                }
            } else {
                let command = try interactiveSSHHelperCommand(for: profile)
                try terminalLauncher.launch(command: command, preference: configuration.interactiveTerminal)
                lastProxyMessage = "\(profile.name): Opened interactive SSH in \(configuration.interactiveTerminal.app.displayName)"
            }
        } catch {
            lastProxyMessage = "\(profile.name): Could not open interactive SSH: \(error.localizedDescription)"
        }
    }

    func interactiveTerminalAvailabilityMessage() -> String {
        isInteractiveTerminalAvailable(configuration.interactiveTerminal)
            ? "\(configuration.interactiveTerminal.app.displayName) is available"
            : "\(configuration.interactiveTerminal.app.displayName) is not available"
    }

    func refreshInteractiveTerminalDiscovery() {
        interactiveTerminalInstallations = terminalDiscovery.discoverInstalledTerminals()
    }

    func interactiveTerminalOptions() -> [InteractiveTerminalOption] {
        InteractiveTerminalDiscovery.options(
            for: interactiveTerminalInstallations,
            currentApp: configuration.interactiveTerminal.app
        )
    }

    func isInteractiveTerminalAvailable(_ preference: InteractiveTerminalPreference) -> Bool {
        switch preference.app {
        case .custom:
            let path = preference.customApplicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return !path.isEmpty && FileManager.default.fileExists(atPath: path)
        case .terminal, .iTerm2, .ghostty:
            return interactiveTerminalInstallations.contains { $0.app == preference.app }
        }
    }

    private func connectLaunchProfiles() {
        for profile in configuration.profiles where profile.connectOnLaunch {
            connect(profile)
        }
    }

    private func startTunnel(_ profile: TunnelProfile, message: String, options: SSHLaunchOptions) {
        statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .connecting, message: message)
        lastProxyMessage = "\(profile.name): \(message)"
        tunnelManager.start(profile: profile, options: options, reservedSocksPorts: reservedSocksPorts(excluding: profile.id))
    }

    private func startHop(_ profile: TunnelProfile, resetLog: Bool, options: SSHLaunchOptions = .standard) {
        guard let jumpHost = normalizedJumpHost(for: profile) else {
            lastProxyMessage = "\(profile.name): No jump host configured"
            return
        }
        if resetLog {
            startSSHLogSession(for: profile, verbose: options.verbose)
        }
        hopStatuses[profile.id] = HopRuntimeStatus(profileID: profile.id, jumpHost: jumpHost, health: .connecting, message: "Starting hop connection")
        lastProxyMessage = "\(profile.name): Starting hop connection"
        hopManager.start(profile: profile, options: options)
    }

    private func connectTunnelThroughHop(_ profile: TunnelProfile, token: UUID, options: SSHLaunchOptions) async {
        do {
            let controlMaster = try await ensureHopReady(for: profile, resetLog: false, options: options)
            guard pendingTunnelStartTokens[profile.id] == token else { return }
            let tunnelProfile = JumpHostControlMasterFactory.profile(profile, through: controlMaster)
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .connecting, message: "Starting tunnel through hop")
            lastProxyMessage = "\(profile.name): Starting tunnel through hop"
            pendingTunnelStartTokens[profile.id] = nil
            tunnelManager.start(profile: tunnelProfile, options: options, reservedSocksPorts: reservedSocksPorts(excluding: profile.id))
        } catch {
            guard pendingTunnelStartTokens[profile.id] == token else { return }
            pendingTunnelStartTokens[profile.id] = nil
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .failed, message: "Could not start tunnel through hop: \(error.localizedDescription)")
            lastProxyMessage = "\(profile.name): Could not start tunnel through hop: \(error.localizedDescription)"
        }
    }

    private func connectInteractiveSSHThroughHop(profile: TunnelProfile, interactiveProfile: TunnelProfile) async {
        do {
            _ = try await ensureHopReady(for: interactiveProfile, resetLog: true, options: .standard)
            let command = try interactiveSSHHelperCommand(for: profile, helperCommand: "interactive-ssh-final-ready")
            let markerURL = try createHopInteractiveSessionMarker(profile: profile, interactiveProfile: interactiveProfile)
            do {
                try terminalLauncher.launch(
                    command: command,
                    preference: configuration.interactiveTerminal,
                    activeSessionMarkerURL: markerURL
                )
            } catch {
                interactiveSessionRegistry.removeMarker(at: markerURL)
                throw error
            }
            lastProxyMessage = "\(profile.name): Opened interactive SSH through hop in \(configuration.interactiveTerminal.app.displayName)"
        } catch {
            lastProxyMessage = "\(profile.name): Could not open interactive SSH through hop: \(error.localizedDescription)"
        }
    }

    private func ensureHopReady(
        for profile: TunnelProfile,
        resetLog: Bool,
        options: SSHLaunchOptions,
        timeoutSeconds: TimeInterval = 120
    ) async throws -> JumpHostControlMaster {
        guard hasJumpHost(profile) else {
            throw NSError(domain: "AppState", code: 30, userInfo: [NSLocalizedDescriptionKey: "Jump host is not configured"])
        }
        let jumpHost = normalizedJumpHost(for: profile)
        if let controlMaster = hopManager.controlMaster(for: profile.id), controlMaster.jumpHost == jumpHost {
            return controlMaster
        }

        let currentHealth = hopStatus(for: profile)?.health
        if options.verbose, currentHealth != .healthy {
            startHop(profile, resetLog: resetLog, options: options)
        } else if currentHealth != .connecting, currentHealth != .reconnecting {
            startHop(profile, resetLog: resetLog, options: options)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let controlMaster = hopManager.controlMaster(for: profile.id) {
                return controlMaster
            }
            if let status = hopStatus(for: profile), status.health == .failed || status.health == .unhealthy {
                throw NSError(domain: "AppState", code: 31, userInfo: [NSLocalizedDescriptionKey: status.message])
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw NSError(domain: "AppState", code: 32, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for hop connection"])
    }

    func connectWithVerboseSSHLogging(profileID: UUID) {
        guard let profile = configuration.profiles.first(where: { $0.id == profileID }) else { return }
        diagnosticsSelectedProfileID = profileID
        let options = SSHLaunchOptions(verbose: true)
        startSSHLogSession(for: profile, verbose: true)
        if hasJumpHost(profile) {
            let token = UUID()
            pendingTunnelStartTokens[profile.id] = token
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .connecting, message: "Waiting for hop connection")
            lastProxyMessage = "\(profile.name): Waiting for hop connection"
            Task {
                await connectTunnelThroughHop(profile, token: token, options: options)
            }
        } else {
            startTunnel(profile, message: "Starting verbose SSH tunnel", options: options)
        }
    }

    func connectHopWithVerboseSSHLogging(profileID: UUID) {
        guard let profile = configuration.profiles.first(where: { $0.id == profileID }) else { return }
        diagnosticsSelectedProfileID = profileID
        startHop(profile, resetLog: true, options: SSHLaunchOptions(verbose: true))
    }

    func selectDiagnosticsProfile(_ profileID: UUID) {
        diagnosticsSelectedProfileID = profileID
    }

    func fullSSHLog(for profileID: UUID) -> String {
        (try? sshLogStore.readLog(profileID: profileID)) ?? logs[profileID] ?? ""
    }

    func sshLogURL(for profileID: UUID) -> URL? {
        try? sshLogStore.logURL(profileID: profileID)
    }

    func clearSSHLog(for profileID: UUID) {
        logs[profileID] = ""
        try? sshLogStore.clearLog(profileID: profileID)
    }

    func activeHopInteractiveSessions() -> [ActiveInteractiveSSHSession] {
        interactiveSessionRegistry.activeSessions()
    }

    func activeQuitConnectionWarnings() -> [QuitConnectionWarning] {
        let profileStatuses = configuration.profiles.map { profile in
            ProfileStatusSnapshot(profile: profile, status: status(for: profile), hopStatus: hopStatus(for: profile))
        }
        return QuitConnectionWarningPolicy.warnings(
            profiles: profileStatuses,
            interactiveSessions: interactiveSessionRegistry.activeSessions(),
            socks5Probe: { SOCKS5Probe.probe(port: $0, timeout: 1) }
        )
    }

    func prepareForTermination() {
        pendingConfigurationSaveTask?.cancel()
        pendingPACAppendSourceTask?.cancel()
        pendingTunnelStartTokens.removeAll()
        let tunnelsStopped = tunnelManager.stopAllWaiting(upTo: 4)
        let hopsStopped = hopManager.stopAllWaiting(upTo: 4)
        if !tunnelsStopped || !hopsStopped {
            lastProxyMessage = "Some SSH processes did not confirm exit before app termination"
        }
    }

    private func interactiveSSHHelperCommand(for profile: TunnelProfile) throws -> SSHCommand {
        try interactiveSSHHelperCommand(for: profile, helperCommand: "interactive-ssh")
    }

    private func interactiveSSHHelperCommand(for profile: TunnelProfile, helperCommand: String) throws -> SSHCommand {
        let helperPath = try interactiveSSHHelperPath()
        return SSHCommand(executable: helperPath, arguments: [helperCommand, profile.name])
    }

    private func interactiveSSHHelperPath() throws -> String {
        if let helperURL = Bundle.main.url(forAuxiliaryExecutable: "ssh-autotunnelctl"),
           FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return helperURL.path
        }

        let bundleHelperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("ssh-autotunnelctl")
        if FileManager.default.isExecutableFile(atPath: bundleHelperURL.path) {
            return bundleHelperURL.path
        }

        let siblingHelperURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("ssh-autotunnelctl")
        if FileManager.default.isExecutableFile(atPath: siblingHelperURL.path) {
            return siblingHelperURL.path
        }

        throw NSError(domain: "AppState", code: 20, userInfo: [NSLocalizedDescriptionKey: "Could not find ssh-autotunnelctl helper in the app bundle"])
    }

    private func createHopInteractiveSessionMarker(
        profile: TunnelProfile,
        interactiveProfile: TunnelProfile
    ) throws -> URL {
        guard let jumpHost = normalizedJumpHost(for: interactiveProfile) else {
            throw NSError(domain: "AppState", code: 33, userInfo: [NSLocalizedDescriptionKey: "Jump host is not configured"])
        }
        let session = ActiveInteractiveSSHSession(
            profileID: profile.id,
            profileName: profile.name,
            jumpHost: jumpHost
        )
        return try interactiveSessionRegistry.createMarker(for: session)
    }

    func saveConfiguration() {
        pendingConfigurationSaveTask?.cancel()
        pendingConfigurationSaveTask = nil
        do {
            try ConfigurationContentValidator.validate(configuration)
            try PortConfigurationValidator.validate(configuration)
            let didRestartServers = try restartLocalServersIfNeeded()
            try configurationStore.save(configuration)
            configurationValidationMessage = nil
            refreshNetworkDecision()
            refreshPACAppendSource()
            writePACCopy()
            let didAttemptSystemPACApply: Bool
            if configuration.proxyApplyMode == .activeNetworkServicePAC,
               didRestartServers || systemPACStatus.state != .active || systemPACStatus.expectedPACURL != pacURL {
                didAttemptSystemPACApply = true
                _ = applySystemPAC()
            } else {
                didAttemptSystemPACApply = false
                refreshSystemPACStatus()
            }
            if didRestartServers, !didAttemptSystemPACApply, let activeServerPorts = localServers.activePorts {
                lastProxyMessage = "Local servers restarted: PAC \(activeServerPorts.pacHTTPPort), API \(activeServerPorts.apiHTTPPort), blocking proxy \(activeServerPorts.blockingHTTPProxyPort)"
            }
        } catch let error as PortConfigurationError {
            configurationValidationMessage = error.localizedDescription
            lastProxyMessage = error.localizedDescription
        } catch let error as ConfigurationContentValidationError {
            configurationValidationMessage = error.localizedDescription
            lastProxyMessage = error.localizedDescription
        } catch {
            lastProxyMessage = "Could not save configuration: \(error.localizedDescription)"
        }
    }

    func scheduleConfigurationSave(delaySeconds: TimeInterval = 0.5) {
        pendingConfigurationSaveTask?.cancel()
        pendingConfigurationSaveTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.saveConfiguration()
            }
        }
    }

    func writeSecret(_ value: String, service: String, account: String) throws {
        try restoringWindowFocus {
            try keychain.writeGenericPassword(value, service: service, account: account)
        }
    }

    func credentialAvailability(service: String?, account: String) -> ProfileCredentialAvailability {
        let service = service?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !service.isEmpty, !account.isEmpty else {
            return .notConfigured
        }

        return restoringWindowFocus {
            do {
                return try keychain.genericPasswordExists(service: service, account: account) ? .found : .missing
            } catch {
                return .unreadable(error.localizedDescription)
            }
        }
    }

    func defaultConnectionTemplateSetupInput(for templateID: ConnectionTemplateID) -> ConnectionTemplateSetupInput {
        ConnectionTemplateSetupService.defaultInput(for: templateID, in: configuration)
    }

    func accountSetupCredentialStatus(for input: ConnectionTemplateSetupInput) -> ConnectionTemplateCredentialStatus {
        restoringWindowFocus {
            ConnectionTemplateSetupService.credentialStatus(for: input, checker: keychain)
        }
    }

    @discardableResult
    func applyConnectionTemplateSetup(
        input: ConnectionTemplateSetupInput,
        password: String,
        totpSeed: String
    ) throws -> ConnectionTemplateSetupResult {
        guard let template = ConnectionTemplateSetupService.template(for: input.id) else {
            throw ConnectionTemplateSetupError.unknownTemplate(input.id)
        }

        let resolvedInput = try restoringWindowFocus {
            var resolved = input
            let account = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
            let totpSeed = totpSeed.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !account.isEmpty else { return resolved }

            if !password.isEmpty {
                try keychain.writeGenericPassword(password, service: template.passwordService, account: account)
                resolved.passwordAvailable = true
            } else {
                resolved.passwordAvailable = try keychain.genericPasswordExists(service: template.passwordService, account: account)
            }

            if !totpSeed.isEmpty {
                try keychain.writeGenericPassword(totpSeed, service: template.totpService, account: account)
                resolved.totpSeedAvailable = true
            } else {
                resolved.totpSeedAvailable = try keychain.genericPasswordExists(service: template.totpService, account: account)
            }

            return resolved
        }

        let (updated, result) = try ConnectionTemplateSetupService.apply(input: resolvedInput, to: configuration)
        configuration = updated
        saveConfiguration()
        lastProxyMessage = "Connection saved from \(template.displayName)"
        return result
    }

    func rotateAPIToken() {
        configuration.apiToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        saveConfiguration()
        lastProxyMessage = "Local API token rotated"
    }

    func refreshPACAppendSource(force: Bool = false) {
        let source = configuration.pacAppendSource
        guard source.enabled else {
            clearPACAppendSource(message: "Existing PAC appending disabled")
            return
        }
        guard source.isReadyToLoad else {
            clearPACAppendSource(message: "Existing PAC source location is required")
            return
        }
        guard force || source != loadedPACAppendSource else { return }

        pendingPACAppendSourceTask?.cancel()
        loadedPACAppendSource = source
        appendedPACContent = nil
        pacAppendSourceMessage = "Loading existing PAC from \(source.trimmedLocation)"
        pendingPACAppendSourceTask = Task { [weak self, source] in
            do {
                let content = try await PACAppendSourceLoader.load(source)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.configuration.pacAppendSource == source else { return }
                    self.appendedPACContent = content
                    self.pacAppendSourceMessage = "Loaded existing PAC from \(source.trimmedLocation)"
                    self.writePACCopy()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.configuration.pacAppendSource == source else { return }
                    self.appendedPACContent = nil
                    self.pacAppendSourceMessage = "Could not load existing PAC: \(error.localizedDescription)"
                    self.writePACCopy()
                }
            }
        }
    }

    @discardableResult
    func applySystemPAC() -> Bool {
        defer {
            refreshSystemPACStatus()
        }
        do {
            if networkDecision.shouldDisableProxy {
                try proxyManager.restoreIfNeeded()
                lastProxyMessage = "System PAC disabled by network rule \(networkDecision.matchedRule?.name ?? "")"
            } else {
                let service = try proxyManager.applyPAC(url: pacURL)
                lastProxyMessage = "System PAC set on \(service)"
            }
            return true
        } catch {
            lastProxyMessage = "System PAC failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func enableSystemPACManagement() -> Bool {
        configuration.proxyApplyMode = .activeNetworkServicePAC
        saveConfiguration()
        return systemPACStatus.state == .active || systemPACStatus.state == .staleAutoTunnelPAC
    }

    @discardableResult
    func disableSystemPACManagement() -> Bool {
        configuration.proxyApplyMode = .manual
        let didRestore = restoreSystemPAC()
        saveConfiguration()
        return didRestore
    }

    @discardableResult
    func restoreSystemPAC() -> Bool {
        defer {
            refreshSystemPACStatus()
        }
        do {
            try proxyManager.restoreIfNeeded()
            lastProxyMessage = "System PAC restored"
            return true
        } catch {
            lastProxyMessage = "Could not restore proxy: \(error.localizedDescription)"
            return false
        }
    }

    func importExistingKeychainServices(for profileID: UUID) {
        guard let index = configuration.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let accountByService = sshAuto2FAPresetAccounts()
        switch configuration.profiles[index].name {
        case "CERN lxplus", "CERN LxPlus":
            let account = accountByService[SSHAuto2FAPresets.cernLxplusTOTPService] ?? NSUserName()
            configuration.profiles[index].user = account
            configuration.profiles[index].interactiveHost = "lxplus.cern.ch"
            if configuration.profiles[index].host == "lxplus.cern.ch" {
                configuration.profiles[index].host = "lxtunnel.cern.ch"
                configuration.profiles[index].healthProbe = HealthProbe(host: "lxtunnel.cern.ch", port: 22)
            }
            configuration.profiles[index].keychain.account = account
            if configuration.profiles[index].name == "CERN LxPlus" {
                configuration.profiles[index].keychain.passwordService = SSHAuto2FAPresets.cernLxplusPasswordService
            }
            configuration.profiles[index].keychain.totpService = SSHAuto2FAPresets.cernLxplusTOTPService
        case "PSI Tier-3", "PSI CMS Tier-3":
            let account = sharedPresetAccount(
                services: [SSHAuto2FAPresets.psiTier3PasswordService, SSHAuto2FAPresets.psiTier3TOTPService],
                accountByService: accountByService
            )
            configuration.profiles[index].user = account
            if (configuration.profiles[index].interactiveHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configuration.profiles[index].interactiveHost = configuration.profiles[index].host
            }
            configuration.profiles[index].jumpHost = "\(account)@t3hop01.psi.ch"
            configuration.profiles[index].keychain.account = account
            configuration.profiles[index].keychain.passwordService = SSHAuto2FAPresets.psiTier3PasswordService
            configuration.profiles[index].keychain.totpService = SSHAuto2FAPresets.psiTier3TOTPService
        case "PSI General":
            let account = configuration.profiles[index].keychain.account
            configuration.profiles[index].user = account
            if (configuration.profiles[index].interactiveHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configuration.profiles[index].interactiveHost = configuration.profiles[index].host
            }
            configuration.profiles[index].jumpHost = "\(account)@hopx.psi.ch"
            configuration.profiles[index].keychain.passwordService = SSHAuto2FAPresets.psiGeneralPasswordService
            configuration.profiles[index].keychain.totpService = SSHAuto2FAPresets.psiGeneralTOTPService
        default:
            break
        }
        saveConfiguration()
    }

    func refreshSSHAuto2FAServiceStatuses() {
        restoringWindowFocus {
            sshAuto2FAServiceStatuses = SSHAuto2FAKeychainInspector.inspect(
                account: NSUserName(),
                reader: keychain,
                accountLookup: keychain
            )
        }
    }

    @discardableResult
    func importSSHAuto2FAPresets() -> SSHAuto2FAImportResult {
        let (updated, result) = restoringWindowFocus {
            SSHAuto2FAImporter.apply(
                to: configuration,
                account: NSUserName(),
                accountByService: sshAuto2FAPresetAccounts()
            )
        }
        configuration = updated
        saveConfiguration()
        lastProxyMessage = "Imported ssh-auto2fa presets: \(result.createdProfiles) created, \(result.updatedProfiles) updated"
        return result
    }

    @discardableResult
    func importSSHConfig(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")) throws -> SSHConfigImportResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        let (updated, result) = SSHConfigImporter.apply(to: configuration, configText: text)
        configuration = updated
        saveConfiguration()
        lastProxyMessage = "Imported SSH config: \(result.createdProfiles) created, \(result.updatedProfiles) updated, \(result.skippedHosts) skipped"
        return result
    }

    func managedSSHConfigSnippet() throws -> String {
        try SSHConfigSetupService.managedSnippet(for: configuration)
    }

    @discardableResult
    func installManagedSSHConfig() throws -> SSHConfigInstallResult {
        let result = try SSHConfigSetupService.installManagedConfig(for: configuration)
        let includeMessage = result.updatedMainConfig ? "added include to \(result.mainConfigURL.path)" : "include already present"
        let backupMessage = result.backupURL.map { " Backup: \($0.path)" } ?? ""
        lastProxyMessage = "Installed managed SSH config for \(result.profileCount) profiles: \(includeMessage).\(backupMessage)"
        return result
    }

    @discardableResult
    func addGenericProfile() -> UUID {
        let profile = TunnelProfile(name: "New tunnel", host: "example.org", localSocksPort: nextFreeSocksPort())
        configuration.profiles.append(profile)
        configuration.pacRules.append(PACRule(name: profile.name, domainPattern: "*.example.org", profileID: profile.id))
        saveConfiguration()
        return profile.id
    }

    func reorderProfiles(profileIDs: [UUID]) {
        do {
            configuration = try ProfileConfigurationEditor.reorderProfiles(profileIDs: profileIDs, in: configuration)
            saveConfiguration()
            lastProxyMessage = "Reordered profiles"
        } catch {
            lastProxyMessage = "Could not reorder profiles: \(error.localizedDescription)"
        }
    }

    func deleteProfile(id: UUID, deleteKeychainItems: Bool = false) {
        let profileName = configuration.profiles.first { $0.id == id }?.name
        do {
            let result = try performProfileDeletion(
                ids: [id],
                deleteKeychainItems: deleteKeychainItems
            )
            lastProxyMessage = profileDeletionMessage(profileName: profileName, result: result)
        } catch {
            lastProxyMessage = "Could not delete profile: \(error.localizedDescription)"
        }
    }

    func deleteProfiles(at offsets: IndexSet, deleteKeychainItems: Bool = false) {
        let ids = offsets.map { configuration.profiles[$0].id }
        let profileName = ids.count == 1 ? configuration.profiles.first { $0.id == ids[0] }?.name : nil
        do {
            let result = try performProfileDeletion(
                ids: ids,
                deleteKeychainItems: deleteKeychainItems
            )
            lastProxyMessage = profileDeletionMessage(profileName: profileName, result: result)
        } catch {
            lastProxyMessage = "Could not delete profile: \(error.localizedDescription)"
        }
    }

    func performProfileDeletion(ids: [UUID], deleteKeychainItems: Bool) throws -> ProfileDeletionResult {
        let idSet = Set(ids)
        let keychainItems = deleteKeychainItems
            ? ProfileKeychainCleanupPlanner.removableItems(removingProfileIDs: idSet, from: configuration)
            : []

        for id in ids {
            pendingTunnelStartTokens[id] = nil
            tunnelManager.stop(profileID: id)
            hopManager.stop(profileID: id)
        }

        var updated = configuration
        for id in ids {
            updated = try ProfileConfigurationEditor.delete(profileID: id, in: updated)
        }
        configuration = updated
        statuses = statuses.filter { !idSet.contains($0.key) }
        hopStatuses = hopStatuses.filter { !idSet.contains($0.key) }
        saveConfiguration()

        var deletedKeychainItemCount = 0
        var keychainCleanupError: Error?
        if deleteKeychainItems {
            do {
                deletedKeychainItemCount = try removeKeychainItems(keychainItems)
            } catch {
                keychainCleanupError = error
            }
        }

        return ProfileDeletionResult(
            profileCount: ids.count,
            requestedKeychainCleanup: deleteKeychainItems,
            deletedKeychainItemCount: deletedKeychainItemCount,
            keychainCleanupError: keychainCleanupError
        )
    }

    private func removeKeychainItems(_ items: [GenericPasswordItemReference]) throws -> Int {
        var deletedCount = 0
        for item in items {
            if try keychain.deleteGenericPassword(service: item.service, account: item.account) {
                deletedCount += 1
            }
        }
        return deletedCount
    }

    func profileDeletionMessage(profileName: String?, result: ProfileDeletionResult) -> String {
        let base: String
        if let profileName {
            base = "Deleted profile \(profileName)"
        } else if result.profileCount == 1 {
            base = "Deleted profile"
        } else {
            base = "Deleted \(result.profileCount) profiles"
        }

        if let keychainCleanupError = result.keychainCleanupError {
            return "\(base), but could not delete Keychain items: \(keychainCleanupError.localizedDescription)"
        }
        if result.requestedKeychainCleanup {
            return "\(base). Deleted \(result.deletedKeychainItemCount) Keychain item(s)."
        }
        return base
    }

    func addDisableRuleForCurrentNetwork() {
        refreshNetworkDecision()
        guard let rule = NetworkPolicyRule.disableProxyRule(from: currentNetworkFingerprint) else {
            lastProxyMessage = "Current network does not expose enough fingerprint data for a rule"
            return
        }
        do {
            configuration = try NetworkRuleConfigurationEditor.create(rule: rule, in: configuration)
            saveConfiguration()
            lastProxyMessage = "Added network rule \(rule.name)"
        } catch {
            lastProxyMessage = "Could not add network rule: \(error.localizedDescription)"
        }
    }

    func snapshot() -> AppStatusSnapshot {
        let profileStatuses = configuration.profiles.map { profile in
            ProfileStatusSnapshot(profile: profile, status: status(for: profile), hopStatus: hopStatus(for: profile))
        }
        return AppStatusSnapshot(
            pacURL: pacURL,
            systemPACStatus: systemPACStatus,
            proxyDisabledByNetworkPolicy: networkDecision.shouldDisableProxy,
            matchedNetworkRule: networkDecision.matchedRule?.name,
            networkDisabledProfileIDs: sortedNetworkDisabledProfileIDs(),
            profiles: profileStatuses
        )
    }

    func diagnosticsSnapshot(generatedAt: Date = Date()) -> DiagnosticsSnapshot {
        let profileStatuses = configuration.profiles.map { profile in
            ProfileStatusSnapshot(profile: profile, status: status(for: profile), hopStatus: hopStatus(for: profile))
        }
        let files = diagnosticFileStatuses()
        return DiagnosticsSnapshot(
            generatedAt: generatedAt,
            appIdentifier: AppPaths.appIdentifier,
            pacURL: pacURL,
            statusURL: statusURL,
            proxyApplyMode: configuration.proxyApplyMode,
            systemPACStatus: systemPACStatus,
            proxyDisabledByNetworkPolicy: networkDecision.shouldDisableProxy,
            matchedNetworkRule: networkDecision.matchedRule?.name,
            networkDisabledProfileIDs: sortedNetworkDisabledProfileIDs(),
            configuredPorts: LocalServerPorts(configuration: configuration),
            activePorts: localServers.activePorts,
            currentNetwork: currentNetworkFingerprint,
            profiles: profileStatuses,
            fileStatuses: files,
            systemProxySnapshotExists: files.first { $0.label == "System PAC snapshot" }?.exists == true
        )
    }

    func configurationExport(exportedAt: Date = Date()) -> ConfigurationExport {
        configurationArtifacts.export(configuration: configuration, exportedAt: exportedAt)
    }

    func configurationValidationReport(for export: ConfigurationExport) -> ConfigurationValidationReport {
        configurationArtifacts.validationReport(
            for: export,
            preservingLocalValuesFrom: configuration
        )
    }

    func supportBundle(generatedAt: Date = Date()) -> SupportBundle {
        let diagnostics = diagnosticsSnapshot(generatedAt: generatedAt)
        return configurationArtifacts.supportBundle(
            configuration: configuration,
            diagnostics: diagnostics,
            generatedAt: diagnostics.generatedAt
        )
    }

    private func sshAuto2FAPresetAccounts() -> [String: String] {
        SSHAuto2FAKeychainInspector.discoveredAccounts(account: NSUserName(), accountLookup: keychain)
    }

    private func sharedPresetAccount(services: [String], accountByService: [String: String]) -> String {
        let accounts = services.compactMap { accountByService[$0] }
        guard Set(accounts).count == 1, let account = accounts.first else {
            return NSUserName()
        }
        return account
    }

    private func restoringWindowFocus<T>(_ operation: () throws -> T) rethrows -> T {
        let restorer = AppWindowFocusRestorer.capture()
        defer {
            restorer.restore()
        }
        return try operation()
    }

    func importConfigurationExport(_ export: ConfigurationExport) -> ControlResponse {
        do {
            let imported = try configurationArtifacts.importConfiguration(
                from: export,
                preservingLocalValuesFrom: configuration
            )
            let backupURL = try configurationStore.backupCurrentConfiguration(
                label: "pre-import",
                retaining: ConfigurationStore.defaultPreImportBackupRetentionCount
            )
            let importedProfileIDs = Set(imported.profiles.map(\.id))
            for profile in configuration.profiles where !importedProfileIDs.contains(profile.id) {
                pendingTunnelStartTokens[profile.id] = nil
                tunnelManager.stop(profileID: profile.id)
                hopManager.stop(profileID: profile.id)
            }
            statuses = statuses.filter { importedProfileIDs.contains($0.key) }
            hopStatuses = hopStatuses.filter { importedProfileIDs.contains($0.key) }
            configuration = imported
            saveConfiguration()
            let backupMessage = backupURL.map { " Backup: \($0.path)" } ?? ""
            let message = configurationValidationMessage ?? "Imported configuration.\(backupMessage)"
            lastProxyMessage = message
            return ControlResponse(
                ok: configurationValidationMessage == nil,
                message: message,
                status: snapshot()
            )
        } catch {
            let message = "Could not import configuration: \(error.localizedDescription)"
            lastProxyMessage = message
            return ControlResponse(ok: false, message: message, status: snapshot())
        }
    }

    private func setupNotificationCallbacks() {
        notifications.onReconnectTunnel = { [weak self] profileID in
            Task { @MainActor in
                guard let self, let profile = self.configuration.profiles.first(where: { $0.id == profileID }) else { return }
                self.reconnect(profile)
            }
        }
        notifications.onReconnectHop = { [weak self] profileID in
            Task { @MainActor in
                guard let self, let profile = self.configuration.profiles.first(where: { $0.id == profileID }) else { return }
                self.reconnectHop(profile)
            }
        }
    }

    private func setupHopCallbacks() {
        hopManager.onKeychainAccessCompleted = {
            Task { @MainActor in
                AppWindowFocusRestorer.restoreVisibleWindows()
            }
        }
        hopManager.onStatusChange = { [weak self] status in
            guard let self else { return }
            let previous = self.hopStatuses[status.profileID]
            self.hopStatuses[status.profileID] = status
            if let profile = self.configuration.profiles.first(where: { $0.id == status.profileID }) {
                self.lastProxyMessage = "\(profile.name) hop: \(status.message)"
                self.deliverConnectionNotification(
                    profile: profile,
                    previous: previous?.health,
                    current: status.health,
                    kind: .hop,
                    message: status.message
                )
            }
        }
        hopManager.onLog = { [weak self] profileID, text in
            DispatchQueue.main.async {
                self?.appendSSHLog(text, profileID: profileID)
            }
        }
    }

    private func setupTunnelCallbacks() {
        tunnelManager.onKeychainAccessCompleted = {
            Task { @MainActor in
                AppWindowFocusRestorer.restoreVisibleWindows()
            }
        }
        tunnelManager.onStatusChange = { [weak self] status in
            guard let self else { return }
            let previous = self.statuses[status.profileID]
            self.statuses[status.profileID] = status
            if let profile = self.configuration.profiles.first(where: { $0.id == status.profileID }) {
                self.lastProxyMessage = "\(profile.name): \(status.message)"
                self.deliverConnectionNotification(
                    profile: profile,
                    previous: previous?.health,
                    current: status.health,
                    kind: .tunnel,
                    message: status.message
                )
            }
            self.writePACCopy()
            if self.configuration.proxyApplyMode == .activeNetworkServicePAC {
                self.applySystemPAC()
            } else {
                self.refreshSystemPACStatus()
            }
        }
        tunnelManager.onLog = { [weak self] profileID, text in
            DispatchQueue.main.async {
                self?.appendSSHLog(text, profileID: profileID)
            }
        }
    }

    private func deliverConnectionNotification(
        profile: TunnelProfile,
        previous: TunnelHealth?,
        current: TunnelHealth,
        kind: ConnectionKind,
        message: String
    ) {
        switch profile.notificationPolicy {
        case .disabled:
            return
        case .failuresAndRecoveries:
            if let event = TunnelNotificationPolicy.event(previous: previous, current: current, kind: kind) {
                notifications.deliver(event: event, profileID: profile.id, profileName: profile.name, message: message)
            }
        case .allStatusChanges:
            guard previous != current else { return }
            if let event = TunnelNotificationPolicy.event(previous: previous, current: current, kind: kind) {
                notifications.deliver(event: event, profileID: profile.id, profileName: profile.name, message: message)
            } else {
                notifications.deliverStatusChange(
                    kind: kind,
                    profileID: profile.id,
                    profileName: profile.name,
                    health: current,
                    message: message
                )
            }
        }
    }

    private func appendSSHLog(_ text: String, profileID: UUID) {
        let current = logs[profileID] ?? ""
        let combined = current + text
        logs[profileID] = String(combined.suffix(120_000))
        try? sshLogStore.append(text, profileID: profileID)
    }

    private func startSSHLogSession(for profile: TunnelProfile, verbose: Bool) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let mode = verbose ? "verbose SSH diagnostics (-vvv)" : "standard SSH"
        let jumpHost = normalizedJumpHost(for: profile).map { "Jump host: \($0)\n" } ?? ""
        let header = """
        === \(profile.name) \(mode) started at \(timestamp) ===
        Host: \(profile.sshDestination)
        \(jumpHost)\
        Local SOCKS port: \(profile.localSocksPort)

        """
        logs[profile.id] = header
        try? sshLogStore.replaceLog(profileID: profile.id, with: header)
    }

    private func startServers() {
        do {
            try PortConfigurationValidator.validate(configuration)
            try localServers.start(ports: LocalServerPorts(configuration: configuration))
        } catch let error as PortConfigurationError {
            configurationValidationMessage = error.localizedDescription
            lastProxyMessage = error.localizedDescription
        } catch {
            lastProxyMessage = "Local server failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func restartLocalServersIfNeeded() throws -> Bool {
        let ports = LocalServerPorts(configuration: configuration)
        return try localServers.restartIfNeeded(ports: ports)
    }

    private func makeLocalServer(role: LocalServerRole, port: Int) throws -> LocalHTTPServer {
        switch role {
        case .pac:
            try LocalHTTPServer(port: port, label: "dev.clange.ssh-autotunnel.pac") { [weak self] request in
                self?.handlePACRequest(request) ?? .error(503, "Unavailable", "App state is unavailable")
            }
        case .blockingProxy:
            try LocalHTTPServer(port: port, label: "dev.clange.ssh-autotunnel.blocking-proxy") { [weak self] request in
                self?.handleBlockingProxyRequest(request) ?? .error(503, "Unavailable", "App state is unavailable")
            }
        case .api:
            try LocalHTTPServer(port: port, label: "dev.clange.ssh-autotunnel.api") { [weak self] request in
                self?.handleAPIRequest(request) ?? .error(503, "Unavailable", "App state is unavailable")
            }
        }
    }

    private nonisolated func handleBlockingProxyRequest(_ request: HTTPRequest) -> HTTPResponse {
        DispatchQueue.main.sync {
            BlockingProxyResponder.response(for: request, statusURL: statusURL)
        }
    }

    private nonisolated func handlePACRequest(_ request: HTTPRequest) -> HTTPResponse {
        DispatchQueue.main.sync {
            switch request.routePath {
            case "/proxy.pac":
                return HTTPResponse(
                    headers: [
                        "Content-Type": "application/x-ns-proxy-autoconfig; charset=utf-8",
                        "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
                        "Pragma": "no-cache"
                    ],
                    body: Data(currentPAC().utf8)
                )
            case "/status.json":
                return .json(snapshot(), encoder: jsonEncoder)
            case "/status":
                return .text(statusHTML(), contentType: "text/html; charset=utf-8")
            default:
                return .error(404, "Not Found", "Unknown local route")
            }
        }
    }

    private nonisolated func handleAPIRequest(_ request: HTTPRequest) -> HTTPResponse {
        DispatchQueue.main.sync {
            ControlAPIRouter(
                tokenProvider: { self.configuration.apiToken },
                statusProvider: { ControlResponse(ok: true, message: "OK", status: self.snapshot()) },
                controlHandler: self.handleControlRequest,
                encoder: self.jsonEncoder
            ).response(for: request)
        }
    }

    private func handleControlRequest(_ request: ControlRequest) -> ControlResponse {
        AppControlRequestDispatcher(appState: self).response(for: request)
    }

    private func diagnosticFileStatuses() -> [DiagnosticFileStatus] {
        let coreFiles = [
            diagnosticFileStatus(
                label: "Application Support",
                urlProvider: AppPaths.applicationSupportDirectory,
                expectedPermissions: FileProtection.privateDirectoryPermissions
            ),
            diagnosticFileStatus(
                label: "Configuration",
                urlProvider: AppPaths.configurationURL,
                expectedPermissions: FileProtection.privateFilePermissions
            ),
            diagnosticFileStatus(
                label: "Generated PAC copy",
                urlProvider: AppPaths.pacCopyURL,
                expectedPermissions: FileProtection.privateFilePermissions
            ),
            diagnosticFileStatus(
                label: "System PAC snapshot",
                urlProvider: AppPaths.proxySnapshotURL,
                expectedPermissions: FileProtection.privateFilePermissions
            )
        ]
        let sshLogs = configuration.profiles.map { profile in
            diagnosticFileStatus(
                label: "SSH log: \(profile.name)",
                urlProvider: { try sshLogStore.logURL(profileID: profile.id) },
                expectedPermissions: FileProtection.privateFilePermissions
            )
        }
        return coreFiles + sshLogs
    }

    private func diagnosticFileStatus(
        label: String,
        urlProvider: () throws -> URL,
        expectedPermissions: Int
    ) -> DiagnosticFileStatus {
        do {
            let url = try urlProvider()
            let exists = FileManager.default.fileExists(atPath: url.path)
            let permissions = try FileProtection.posixPermissions(of: url)
            return DiagnosticFileStatus(
                label: label,
                path: url.path,
                exists: exists,
                posixPermissions: permissions.map { String(format: "%03o", $0) },
                isPrivate: permissions == expectedPermissions
            )
        } catch {
            return DiagnosticFileStatus(
                label: label,
                path: "Unavailable: \(error.localizedDescription)",
                exists: false,
                posixPermissions: nil,
                isPrivate: false
            )
        }
    }

    func resolveProfile(id: UUID?, name: String?) -> TunnelProfile? {
        if let id {
            return configuration.profiles.first { $0.id == id }
        }
        if let name {
            return configuration.profiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        }
        return nil
    }

    private func normalizedJumpHost(for profile: TunnelProfile) -> String? {
        let jumpHost = profile.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return jumpHost.isEmpty ? nil : jumpHost
    }

    private func isActive(_ health: TunnelHealth) -> Bool {
        switch health {
        case .healthy, .connecting, .degraded, .reconnecting:
            true
        case .stopped, .unhealthy, .failed:
            false
        }
    }

    func refreshNetworkDecision() {
        currentNetworkFingerprint = networkIdentity.currentFingerprint()
        networkDecision = networkIdentity.evaluate(configuration: configuration, fingerprint: currentNetworkFingerprint)
    }

    func refreshSystemPACStatus() {
        systemPACStatus = proxyManager.pacStatus(expectedURL: pacURL)
    }

    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshNetworkDecision()
                self.writePACCopy()
                if self.configuration.proxyApplyMode == .activeNetworkServicePAC {
                    self.applySystemPAC()
                } else {
                    self.refreshSystemPACStatus()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.clange.ssh-autotunnel.network"))
        pathMonitor = monitor
    }

    private func currentPAC() -> String {
        let context = PACGenerationContext(
            configuration: configuration,
            statuses: statuses,
            proxyDisabledByNetworkPolicy: networkDecision.shouldDisableProxy,
            networkDisabledProfileIDs: networkDecision.disabledProfileIDs,
            appendedPAC: configuration.pacAppendSource.isReadyToLoad ? appendedPACContent : nil
        )
        return PACGenerator.generate(context: context)
    }

    private func clearPACAppendSource(message: String) {
        pendingPACAppendSourceTask?.cancel()
        loadedPACAppendSource = nil
        appendedPACContent = nil
        pacAppendSourceMessage = message
    }

    private func sortedNetworkDisabledProfileIDs() -> [UUID] {
        networkDecision.disabledProfileIDs.sorted { $0.uuidString < $1.uuidString }
    }

    func writePACCopy() {
        do {
            let url = try AppPaths.pacCopyURL()
            try currentPAC().write(to: url, atomically: true, encoding: .utf8)
            try FileProtection.protectFile(url)
        } catch {
            lastProxyMessage = "Could not write PAC copy: \(error.localizedDescription)"
        }
    }

    private func statusHTML() -> String {
        let rows = configuration.profiles.map { profile in
            let status = status(for: profile)
            return "<tr><td>\(escape(profile.name))</td><td>\(escape(status.health.rawValue))</td><td>\(escape(socksPortSummary(profile: profile, status: status)))</td><td>\(escape(status.message))</td></tr>"
        }.joined()
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>SSH AutoTunnel</title>
        <style>body{font:14px -apple-system;margin:32px;line-height:1.4}table{border-collapse:collapse}td,th{border-bottom:1px solid #ddd;padding:6px 12px;text-align:left}code{background:#eee;padding:2px 4px;border-radius:4px}</style>
        </head><body>
        <h1>SSH AutoTunnel</h1>
        <p>PAC URL: <code>\(escape(pacURL))</code></p>
        <p>Network policy: \(networkDecision.shouldDisableProxy ? "proxy disabled" : "proxy allowed") \(escape(networkDecision.matchedRule?.name ?? ""))</p>
        <table><tr><th>Profile</th><th>Status</th><th>SOCKS</th><th>Message</th></tr>\(rows)</table>
        </body></html>
        """
    }

    private func socksPortSummary(profile: TunnelProfile, status: TunnelRuntimeStatus) -> String {
        guard let effectivePort = status.effectiveLocalSocksPort, effectivePort != profile.localSocksPort else {
            return "127.0.0.1:\(profile.localSocksPort)"
        }
        return "127.0.0.1:\(effectivePort) (configured \(profile.localSocksPort))"
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func nextFreeSocksPort() -> Int {
        let used = Set(configuration.profiles.map(\.localSocksPort) + [
            configuration.pacHTTPPort,
            configuration.apiHTTPPort,
            configuration.blockingHTTPProxyPort
        ])
        var port = 1080
        while used.contains(port) {
            port += 1
        }
        return port
    }

    private func reservedSocksPorts(excluding profileID: UUID) -> Set<Int> {
        var ports = Set([
            configuration.pacHTTPPort,
            configuration.apiHTTPPort,
            configuration.blockingHTTPProxyPort
        ])
        ports.formUnion(configuration.profiles.compactMap { profile in
            profile.id == profileID ? nil : profile.localSocksPort
        })
        ports.formUnion(statuses.values.compactMap { status in
            status.profileID == profileID ? nil : status.effectiveLocalSocksPort
        })
        return ports
    }
}
