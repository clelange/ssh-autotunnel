import AppKit
import Foundation
import Network
import SSHAutoTunnelCore
import SwiftUI

private struct ProfileDeletionResult {
    var profileCount: Int
    var requestedKeychainCleanup: Bool
    var deletedKeychainItemCount: Int
    var keychainCleanupError: Error?
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
    @Published var configurationValidationMessage: String?
    @Published var sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus] = []
    @Published var pacAppendSourceMessage = "Existing PAC appending disabled"

    private let configurationStore: ConfigurationStore
    private let tunnelManager = TunnelManager()
    private let hopManager = HopConnectionManager()
    private let keychain = KeychainService()
    private let networkIdentity = NetworkIdentityService()
    private let proxyManager = SystemProxyManager()
    private let notifications = AppNotificationService()
    private let sshLogStore = SSHLogStore()
    private let terminalLauncher = InteractiveTerminalLauncher()
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
        refreshPACAppendSource(force: true)
        writePACCopy()
    }

    var pacURL: String {
        "http://127.0.0.1:\(localServers.activePorts?.pacHTTPPort ?? configuration.pacHTTPPort)/proxy.pac?v=\(pacVersion)"
    }

    var statusURL: String {
        "http://127.0.0.1:\(localServers.activePorts?.pacHTTPPort ?? configuration.pacHTTPPort)/status"
    }

    private var pacVersion: Int {
        let statusHash = statuses.values
            .sorted { $0.profileID.uuidString < $1.profileID.uuidString }
            .map { "\($0.profileID.uuidString):\($0.health.rawValue)" }
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
                await connectTunnelThroughHop(profile, token: token)
            }
        } else {
            startTunnel(profile, message: "Starting tunnel")
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
                await connectTunnelThroughHop(profile, token: token)
            }
        } else {
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .reconnecting, message: "Reconnect requested")
            lastProxyMessage = "\(profile.name): Reconnect requested"
            tunnelManager.reconnect(profile: profile)
        }
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
        hopManager.reconnect(profile: profile)
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
        terminalLauncher.isAvailable(configuration.interactiveTerminal)
            ? "\(configuration.interactiveTerminal.app.displayName) is available"
            : "\(configuration.interactiveTerminal.app.displayName) is not available"
    }

    private func startTunnel(_ profile: TunnelProfile, message: String) {
        statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .connecting, message: message)
        lastProxyMessage = "\(profile.name): \(message)"
        tunnelManager.start(profile: profile)
    }

    private func startHop(_ profile: TunnelProfile, resetLog: Bool) {
        guard let jumpHost = normalizedJumpHost(for: profile) else {
            lastProxyMessage = "\(profile.name): No jump host configured"
            return
        }
        if resetLog {
            startSSHLogSession(for: profile, verbose: false)
        }
        hopStatuses[profile.id] = HopRuntimeStatus(profileID: profile.id, jumpHost: jumpHost, health: .connecting, message: "Starting hop connection")
        lastProxyMessage = "\(profile.name): Starting hop connection"
        hopManager.start(profile: profile)
    }

    private func connectTunnelThroughHop(_ profile: TunnelProfile, token: UUID) async {
        do {
            let controlMaster = try await ensureHopReady(for: profile, resetLog: false)
            guard pendingTunnelStartTokens[profile.id] == token else { return }
            let tunnelProfile = JumpHostControlMasterFactory.profile(profile, through: controlMaster)
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .connecting, message: "Starting tunnel through hop")
            lastProxyMessage = "\(profile.name): Starting tunnel through hop"
            pendingTunnelStartTokens[profile.id] = nil
            tunnelManager.start(profile: tunnelProfile)
        } catch {
            guard pendingTunnelStartTokens[profile.id] == token else { return }
            pendingTunnelStartTokens[profile.id] = nil
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .failed, message: "Could not start tunnel through hop: \(error.localizedDescription)")
            lastProxyMessage = "\(profile.name): Could not start tunnel through hop: \(error.localizedDescription)"
        }
    }

    private func connectInteractiveSSHThroughHop(profile: TunnelProfile, interactiveProfile: TunnelProfile) async {
        do {
            _ = try await ensureHopReady(for: interactiveProfile, resetLog: true)
            let command = try interactiveSSHHelperCommand(for: profile, helperCommand: "interactive-ssh-final-ready")
            try terminalLauncher.launch(command: command, preference: configuration.interactiveTerminal)
            lastProxyMessage = "\(profile.name): Opened interactive SSH through hop in \(configuration.interactiveTerminal.app.displayName)"
        } catch {
            lastProxyMessage = "\(profile.name): Could not open interactive SSH through hop: \(error.localizedDescription)"
        }
    }

    private func ensureHopReady(
        for profile: TunnelProfile,
        resetLog: Bool,
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
        if currentHealth != .connecting, currentHealth != .reconnecting {
            startHop(profile, resetLog: resetLog)
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
        guard var profile = configuration.profiles.first(where: { $0.id == profileID }) else { return }
        if !profile.extraSSHOptions.contains("-vvv") {
            profile.extraSSHOptions.append("-vvv")
        }
        startSSHLogSession(for: profile, verbose: true)
        if hasJumpHost(profile) {
            let token = UUID()
            pendingTunnelStartTokens[profile.id] = token
            statuses[profile.id] = TunnelRuntimeStatus(profileID: profile.id, health: .connecting, message: "Waiting for hop connection")
            lastProxyMessage = "\(profile.name): Waiting for hop connection"
            Task {
                await connectTunnelThroughHop(profile, token: token)
            }
        } else {
            startTunnel(profile, message: "Starting verbose SSH tunnel")
        }
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

    func saveConfiguration() {
        pendingConfigurationSaveTask?.cancel()
        pendingConfigurationSaveTask = nil
        do {
            try PortConfigurationValidator.validate(configuration)
            let didRestartServers = try restartLocalServersIfNeeded()
            try configurationStore.save(configuration)
            configurationValidationMessage = nil
            refreshNetworkDecision()
            refreshPACAppendSource()
            writePACCopy()
            if didRestartServers, let activeServerPorts = localServers.activePorts {
                lastProxyMessage = "Local servers restarted: PAC \(activeServerPorts.pacHTTPPort), API \(activeServerPorts.apiHTTPPort), blocking proxy \(activeServerPorts.blockingHTTPProxyPort)"
            }
        } catch let error as PortConfigurationError {
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

    func defaultAccountSetupInputs() -> [AccountSetupInput] {
        AccountSetupService.defaultInputs(in: configuration)
    }

    func accountSetupCredentialStatus(for input: AccountSetupInput) -> AccountSetupCredentialStatus {
        restoringWindowFocus {
            AccountSetupService.credentialStatus(for: input, checker: keychain)
        }
    }

    @discardableResult
    func applyAccountSetup(
        inputs: [AccountSetupInput],
        passwords: [AccountPresetID: String],
        totpSeeds: [AccountPresetID: String]
    ) throws -> AccountSetupResult {
        let resolvedInputs = try restoringWindowFocus {
            try inputs.map { input in
                guard input.isSelected, let preset = AccountSetupService.preset(for: input.id) else {
                    return input
                }

                var resolved = input
                let account = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
                let password = passwords[input.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let totpSeed = totpSeeds[input.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard !account.isEmpty else { return resolved }

                if !password.isEmpty {
                    try keychain.writeGenericPassword(password, service: preset.passwordService, account: account)
                    resolved.passwordAvailable = true
                } else {
                    resolved.passwordAvailable = try keychain.genericPasswordExists(service: preset.passwordService, account: account)
                }

                if !totpSeed.isEmpty {
                    try keychain.writeGenericPassword(totpSeed, service: preset.totpService, account: account)
                    resolved.totpSeedAvailable = true
                } else {
                    resolved.totpSeedAvailable = try keychain.genericPasswordExists(service: preset.totpService, account: account)
                }

                return resolved
            }
        }
        let (updated, result) = try AccountSetupService.apply(inputs: resolvedInputs, to: configuration)
        configuration = updated
        saveConfiguration()
        lastProxyMessage = "Setup saved: \(result.configuredAccounts) accounts, \(configuration.profiles.count) tunnel profiles"
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
    func restoreSystemPAC() -> Bool {
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

    func addGenericProfile() {
        let profile = TunnelProfile(name: "New tunnel", host: "example.org", localSocksPort: nextFreeSocksPort())
        configuration.profiles.append(profile)
        configuration.pacRules.append(PACRule(name: profile.name, domainPattern: "*.example.org", profileID: profile.id))
        saveConfiguration()
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

    private func performProfileDeletion(ids: [UUID], deleteKeychainItems: Bool) throws -> ProfileDeletionResult {
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

    private func profileDeletionMessage(profileName: String?, result: ProfileDeletionResult) -> String {
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
        ConfigurationExportService.makeExport(from: configuration, exportedAt: exportedAt)
    }

    func configurationValidationReport(for export: ConfigurationExport) -> ConfigurationValidationReport {
        ConfigurationExportService.validationReport(
            for: export,
            preservingLocalValuesFrom: configuration
        )
    }

    func supportBundle(generatedAt: Date = Date()) -> SupportBundle {
        let diagnostics = diagnosticsSnapshot(generatedAt: generatedAt)
        return ConfigurationExportService.makeSupportBundle(
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
            let imported = try ConfigurationExportService.importConfiguration(
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
                if let event = TunnelNotificationPolicy.event(previous: previous?.health, current: status.health, kind: .hop) {
                    self.notifications.deliver(event: event, profileID: profile.id, profileName: profile.name, message: status.message)
                }
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
                if let event = TunnelNotificationPolicy.event(previous: previous?.health, current: status.health) {
                    self.notifications.deliver(event: event, profileID: profile.id, profileName: profile.name, message: status.message)
                }
            }
            self.writePACCopy()
            if self.configuration.proxyApplyMode == .activeNetworkServicePAC {
                self.applySystemPAC()
            }
        }
        tunnelManager.onLog = { [weak self] profileID, text in
            DispatchQueue.main.async {
                self?.appendSSHLog(text, profileID: profileID)
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
        let header = """
        === \(profile.name) \(mode) started at \(timestamp) ===
        Host: \(profile.sshDestination)
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
            if request.path.hasPrefix("/proxy.pac") {
                return HTTPResponse(
                    headers: [
                        "Content-Type": "application/x-ns-proxy-autoconfig; charset=utf-8",
                        "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
                        "Pragma": "no-cache"
                    ],
                    body: Data(currentPAC().utf8)
                )
            }
            if request.path.hasPrefix("/status.json") {
                return .json(snapshot(), encoder: jsonEncoder)
            }
            return .text(statusHTML(), contentType: "text/html; charset=utf-8")
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
        let profile = resolveProfile(id: request.profileID, name: request.profileName)
        switch request.action {
        case .connect:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: snapshot()) }
            connect(profile)
            return ControlResponse(ok: true, message: "Connecting \(profile.name)", status: snapshot())
        case .disconnect:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: snapshot()) }
            disconnect(profile)
            return ControlResponse(ok: true, message: "Disconnecting \(profile.name)", status: snapshot())
        case .reconnect:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: snapshot()) }
            reconnect(profile)
            return ControlResponse(ok: true, message: "Reconnecting \(profile.name)", status: snapshot())
        case .connectHop:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: snapshot()) }
            guard hasJumpHost(profile) else { return ControlResponse(ok: false, message: "Profile has no jump host", status: snapshot()) }
            connectHop(profile)
            return ControlResponse(ok: true, message: "Connecting hop for \(profile.name)", status: snapshot())
        case .disconnectHop:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: snapshot()) }
            guard hasJumpHost(profile) else { return ControlResponse(ok: false, message: "Profile has no jump host", status: snapshot()) }
            disconnectHop(profile)
            return ControlResponse(ok: true, message: "Disconnecting hop for \(profile.name)", status: snapshot())
        case .reconnectHop:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: snapshot()) }
            guard hasJumpHost(profile) else { return ControlResponse(ok: false, message: "Profile has no jump host", status: snapshot()) }
            reconnectHop(profile)
            return ControlResponse(ok: true, message: "Reconnecting hop for \(profile.name)", status: snapshot())
        case .reloadPAC:
            refreshPACAppendSource(force: true)
            writePACCopy()
            return ControlResponse(ok: true, message: "PAC reloaded", status: snapshot())
        case .pacURL:
            return ControlResponse(ok: true, message: pacURL, status: snapshot())
        case .status:
            return ControlResponse(ok: true, message: "OK", status: snapshot())
        case .applySystemPAC:
            let ok = applySystemPAC()
            return ControlResponse(ok: ok, message: lastProxyMessage, status: snapshot())
        case .restoreSystemPAC:
            let ok = restoreSystemPAC()
            return ControlResponse(ok: ok, message: lastProxyMessage, status: snapshot())
        case .importSSHAuto2FA:
            let result = importSSHAuto2FAPresets()
            return ControlResponse(
                ok: true,
                message: "Imported ssh-auto2fa presets: \(result.createdProfiles) created, \(result.updatedProfiles) updated, \(result.createdPACRules) PAC rules added",
                status: snapshot()
            )
        case .checkSSHAuto2FA:
            refreshSSHAuto2FAServiceStatuses()
            return ControlResponse(
                ok: true,
                message: "Checked \(sshAuto2FAServiceStatuses.count) ssh-auto2fa Keychain services",
                status: snapshot(),
                sshAuto2FAServiceStatuses: sshAuto2FAServiceStatuses
            )
        case .importSSHConfig:
            do {
                let result = try importSSHConfig()
                return ControlResponse(
                    ok: true,
                    message: "Imported SSH config: \(result.createdProfiles) created, \(result.updatedProfiles) updated, \(result.skippedHosts) skipped",
                    status: snapshot()
                )
            } catch {
                return ControlResponse(ok: false, message: "Could not import SSH config: \(error.localizedDescription)", status: snapshot())
            }
        case .createProfile:
            guard let requestProfile = request.profile else {
                return ControlResponse(ok: false, message: ProfileConfigurationEditorError.missingProfilePayload.localizedDescription, status: snapshot())
            }
            do {
                let updated = try ProfileConfigurationEditor.create(profile: requestProfile, in: configuration)
                configuration = updated
                saveConfiguration()
                return ControlResponse(ok: true, message: "Created profile \(requestProfile.name)", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create profile: \(error.localizedDescription)", status: snapshot())
            }
        case .updateProfile:
            guard let requestProfile = request.profile else {
                return ControlResponse(ok: false, message: ProfileConfigurationEditorError.missingProfilePayload.localizedDescription, status: snapshot())
            }
            do {
                let updated = try ProfileConfigurationEditor.update(
                    profile: requestProfile,
                    matchingID: request.profileID,
                    matchingName: request.profileName,
                    in: configuration
                )
                configuration = updated
                saveConfiguration()
                return ControlResponse(ok: true, message: "Updated profile \(requestProfile.name)", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not update profile: \(error.localizedDescription)", status: snapshot())
            }
        case .deleteProfile:
            guard let profile else { return ControlResponse(ok: false, message: "Profile not found", status: snapshot()) }
            do {
                let result = try performProfileDeletion(
                    ids: [profile.id],
                    deleteKeychainItems: request.deleteKeychainItems == true
                )
                let message = profileDeletionMessage(profileName: profile.name, result: result)
                return ControlResponse(
                    ok: result.keychainCleanupError == nil,
                    message: message,
                    status: snapshot()
                )
            } catch {
                return ControlResponse(ok: false, message: "Could not delete profile: \(error.localizedDescription)", status: snapshot())
            }
        case .createPACRule:
            guard let requestRule = request.pacRule else {
                return ControlResponse(ok: false, message: PACRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: snapshot())
            }
            do {
                configuration = try PACRuleConfigurationEditor.create(rule: requestRule, in: configuration)
                saveConfiguration()
                return ControlResponse(ok: true, message: "Created PAC rule \(requestRule.name)", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create PAC rule: \(error.localizedDescription)", status: snapshot())
            }
        case .updatePACRule:
            guard let requestRule = request.pacRule else {
                return ControlResponse(ok: false, message: PACRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: snapshot())
            }
            do {
                configuration = try PACRuleConfigurationEditor.update(
                    rule: requestRule,
                    matchingID: request.pacRuleID,
                    matchingName: request.pacRuleName,
                    in: configuration
                )
                saveConfiguration()
                return ControlResponse(ok: true, message: "Updated PAC rule \(requestRule.name)", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not update PAC rule: \(error.localizedDescription)", status: snapshot())
            }
        case .deletePACRule:
            do {
                configuration = try PACRuleConfigurationEditor.delete(
                    ruleID: request.pacRuleID,
                    ruleName: request.pacRuleName,
                    in: configuration
                )
                saveConfiguration()
                return ControlResponse(ok: true, message: "Deleted PAC rule", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not delete PAC rule: \(error.localizedDescription)", status: snapshot())
            }
        case .createNetworkRule:
            guard let requestRule = request.networkRule else {
                return ControlResponse(ok: false, message: NetworkRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: snapshot())
            }
            do {
                configuration = try NetworkRuleConfigurationEditor.create(rule: requestRule, in: configuration)
                saveConfiguration()
                return ControlResponse(ok: true, message: "Created network rule \(requestRule.name)", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create network rule: \(error.localizedDescription)", status: snapshot())
            }
        case .updateNetworkRule:
            guard let requestRule = request.networkRule else {
                return ControlResponse(ok: false, message: NetworkRuleConfigurationEditorError.missingRulePayload.localizedDescription, status: snapshot())
            }
            do {
                configuration = try NetworkRuleConfigurationEditor.update(
                    rule: requestRule,
                    matchingID: request.networkRuleID,
                    matchingName: request.networkRuleName,
                    in: configuration
                )
                saveConfiguration()
                return ControlResponse(ok: true, message: "Updated network rule \(requestRule.name)", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not update network rule: \(error.localizedDescription)", status: snapshot())
            }
        case .deleteNetworkRule:
            do {
                configuration = try NetworkRuleConfigurationEditor.delete(
                    ruleID: request.networkRuleID,
                    ruleName: request.networkRuleName,
                    in: configuration
                )
                saveConfiguration()
                return ControlResponse(ok: true, message: "Deleted network rule", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not delete network rule: \(error.localizedDescription)", status: snapshot())
            }
        case .createNetworkRuleFromCurrentNetwork:
            refreshNetworkDecision()
            guard var rule = NetworkPolicyRule.disableProxyRule(from: currentNetworkFingerprint) else {
                return ControlResponse(ok: false, message: "Current network does not expose enough fingerprint data for a rule", status: snapshot())
            }
            if request.profileID != nil || request.profileName != nil {
                guard let profile else {
                    return ControlResponse(ok: false, message: "Profile not found", status: snapshot())
                }
                rule.profileID = profile.id
            }
            do {
                configuration = try NetworkRuleConfigurationEditor.create(rule: rule, in: configuration)
                saveConfiguration()
                return ControlResponse(ok: true, message: "Created network rule \(rule.name)", status: snapshot())
            } catch {
                return ControlResponse(ok: false, message: "Could not create network rule: \(error.localizedDescription)", status: snapshot())
            }
        case .diagnostics:
            return ControlResponse(
                ok: true,
                message: "Diagnostics",
                status: snapshot(),
                diagnostics: diagnosticsSnapshot()
            )
        case .exportConfiguration:
            return ControlResponse(
                ok: true,
                message: "Configuration export",
                status: snapshot(),
                configurationExport: configurationExport()
            )
        case .importConfiguration:
            guard let export = request.configurationExport else {
                return ControlResponse(ok: false, message: "A configuration export payload is required.", status: snapshot())
            }
            return importConfigurationExport(export)
        case .validateConfigurationExport:
            guard let export = request.configurationExport else {
                return ControlResponse(ok: false, message: "A configuration export payload is required.", status: snapshot())
            }
            let report = configurationValidationReport(for: export)
            return ControlResponse(
                ok: report.ok,
                message: report.message,
                status: snapshot(),
                configurationValidation: report
            )
        case .supportBundle:
            let bundle = supportBundle()
            return ControlResponse(
                ok: true,
                message: "Support bundle",
                status: snapshot(),
                supportBundle: bundle
            )
        }
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

    private func resolveProfile(id: UUID?, name: String?) -> TunnelProfile? {
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

    private func refreshNetworkDecision() {
        currentNetworkFingerprint = networkIdentity.currentFingerprint()
        networkDecision = networkIdentity.evaluate(configuration: configuration, fingerprint: currentNetworkFingerprint)
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

    private func writePACCopy() {
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
            return "<tr><td>\(escape(profile.name))</td><td>\(escape(status.health.rawValue))</td><td>\(escape(status.message))</td></tr>"
        }.joined()
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>SSH AutoTunnel</title>
        <style>body{font:14px -apple-system;margin:32px;line-height:1.4}table{border-collapse:collapse}td,th{border-bottom:1px solid #ddd;padding:6px 12px;text-align:left}code{background:#eee;padding:2px 4px;border-radius:4px}</style>
        </head><body>
        <h1>SSH AutoTunnel</h1>
        <p>PAC URL: <code>\(escape(pacURL))</code></p>
        <p>Network policy: \(networkDecision.shouldDisableProxy ? "proxy disabled" : "proxy allowed") \(escape(networkDecision.matchedRule?.name ?? ""))</p>
        <table><tr><th>Profile</th><th>Status</th><th>Message</th></tr>\(rows)</table>
        </body></html>
        """
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
}
