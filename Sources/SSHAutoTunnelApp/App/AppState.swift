import Foundation
import Network
import SSHAutoTunnelCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var statuses: [UUID: TunnelRuntimeStatus] = [:]
    @Published var logs: [UUID: String] = [:]
    @Published var networkDecision = NetworkPolicyDecision(shouldDisableProxy: false, matchedRule: nil)
    @Published var currentNetworkFingerprint = NetworkFingerprint()
    @Published var lastProxyMessage = "System PAC is not enabled"
    @Published var configurationValidationMessage: String?
    @Published var sshAuto2FAServiceStatuses: [SSHAuto2FAServiceStatus] = []

    private let configurationStore: ConfigurationStore
    private let tunnelManager = TunnelManager()
    private let keychain = KeychainService()
    private let networkIdentity = NetworkIdentityService()
    private let proxyManager = SystemProxyManager()
    private let notifications = AppNotificationService()
    private var pathMonitor: NWPathMonitor?
    private var pendingConfigurationSaveTask: Task<Void, Never>?
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
        setupTunnelCallbacks()
        refreshNetworkDecision()
        startServers()
        startNetworkMonitoring()
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

    func connect(_ profile: TunnelProfile) {
        tunnelManager.start(profile: profile)
    }

    func disconnect(_ profile: TunnelProfile) {
        tunnelManager.stop(profileID: profile.id)
    }

    func reconnect(_ profile: TunnelProfile) {
        tunnelManager.reconnect(profile: profile)
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
        try keychain.writeGenericPassword(value, service: service, account: account)
    }

    func rotateAPIToken() {
        configuration.apiToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        saveConfiguration()
        lastProxyMessage = "Local API token rotated"
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
        switch configuration.profiles[index].name {
        case "CERN lxplus":
            configuration.profiles[index].keychain.totpService = SSHAuto2FAPresets.cernLxplusTOTPService
        case "PSI Tier-3":
            configuration.profiles[index].keychain.passwordService = SSHAuto2FAPresets.psiTier3PasswordService
            configuration.profiles[index].keychain.totpService = SSHAuto2FAPresets.psiTier3TOTPService
        default:
            break
        }
        saveConfiguration()
    }

    func refreshSSHAuto2FAServiceStatuses() {
        sshAuto2FAServiceStatuses = SSHAuto2FAKeychainInspector.inspect(account: NSUserName(), reader: keychain)
    }

    @discardableResult
    func importSSHAuto2FAPresets() -> SSHAuto2FAImportResult {
        let (updated, result) = SSHAuto2FAImporter.apply(to: configuration, account: NSUserName())
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

    func deleteProfiles(at offsets: IndexSet) {
        let ids = offsets.map { configuration.profiles[$0].id }
        for id in ids {
            tunnelManager.stop(profileID: id)
        }
        do {
            var updated = configuration
            for id in ids {
                updated = try ProfileConfigurationEditor.delete(profileID: id, in: updated)
            }
            configuration = updated
            saveConfiguration()
        } catch {
            lastProxyMessage = "Could not delete profile: \(error.localizedDescription)"
        }
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
            ProfileStatusSnapshot(profile: profile, status: status(for: profile))
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
            ProfileStatusSnapshot(profile: profile, status: status(for: profile))
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

    private func setupTunnelCallbacks() {
        tunnelManager.onStatusChange = { [weak self] status in
            guard let self else { return }
            let previous = self.statuses[status.profileID]
            self.statuses[status.profileID] = status
            if let profile = self.configuration.profiles.first(where: { $0.id == status.profileID }),
               let event = TunnelNotificationPolicy.event(previous: previous?.health, current: status.health) {
                self.notifications.deliver(event: event, profileName: profile.name, message: status.message)
            }
            self.writePACCopy()
            if self.configuration.proxyApplyMode == .activeNetworkServicePAC {
                self.applySystemPAC()
            }
        }
        tunnelManager.onLog = { [weak self] profileID, text in
            DispatchQueue.main.async {
                guard let self else { return }
                let current = self.logs[profileID] ?? ""
                let combined = current + text
                self.logs[profileID] = String(combined.suffix(12_000))
            }
        }
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
        case .reloadPAC:
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
                tunnelManager.stop(profileID: profile.id)
                configuration = try ProfileConfigurationEditor.delete(profileID: profile.id, in: configuration)
                saveConfiguration()
                return ControlResponse(ok: true, message: "Deleted profile \(profile.name)", status: snapshot())
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
                configurationExport: ConfigurationExportService.makeExport(from: configuration)
            )
        case .importConfiguration:
            guard let export = request.configurationExport else {
                return ControlResponse(ok: false, message: "A configuration export payload is required.", status: snapshot())
            }
            do {
                let imported = try ConfigurationExportService.importConfiguration(
                    from: export,
                    preservingLocalValuesFrom: configuration
                )
                let backupURL = try configurationStore.backupCurrentConfiguration(label: "pre-import")
                let importedProfileIDs = Set(imported.profiles.map(\.id))
                for profile in configuration.profiles where !importedProfileIDs.contains(profile.id) {
                    tunnelManager.stop(profileID: profile.id)
                }
                statuses = statuses.filter { importedProfileIDs.contains($0.key) }
                configuration = imported
                saveConfiguration()
                let backupMessage = backupURL.map { " Backup: \($0.path)" } ?? ""
                return ControlResponse(
                    ok: configurationValidationMessage == nil,
                    message: configurationValidationMessage ?? "Imported configuration.\(backupMessage)",
                    status: snapshot()
                )
            } catch {
                return ControlResponse(ok: false, message: "Could not import configuration: \(error.localizedDescription)", status: snapshot())
            }
        case .supportBundle:
            let diagnostics = diagnosticsSnapshot()
            return ControlResponse(
                ok: true,
                message: "Support bundle",
                status: snapshot(),
                supportBundle: ConfigurationExportService.makeSupportBundle(
                    configuration: configuration,
                    diagnostics: diagnostics,
                    generatedAt: diagnostics.generatedAt
                )
            )
        }
    }

    private func diagnosticFileStatuses() -> [DiagnosticFileStatus] {
        [
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
            networkDisabledProfileIDs: networkDecision.disabledProfileIDs
        )
        return PACGenerator.generate(context: context)
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
