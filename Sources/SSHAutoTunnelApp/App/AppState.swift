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
    private var pacServer: LocalHTTPServer?
    private var blockingProxyServer: LocalHTTPServer?
    private var apiServer: LocalHTTPServer?
    private var activeServerPorts: LocalServerPorts?
    private var pathMonitor: NWPathMonitor?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

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
        "http://127.0.0.1:\(activeServerPorts?.pacHTTPPort ?? configuration.pacHTTPPort)/proxy.pac?v=\(pacVersion)"
    }

    var statusURL: String {
        "http://127.0.0.1:\(activeServerPorts?.pacHTTPPort ?? configuration.pacHTTPPort)/status"
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
        do {
            try PortConfigurationValidator.validate(configuration)
            let didRestartServers = try restartLocalServersIfNeeded()
            try configurationStore.save(configuration)
            configurationValidationMessage = nil
            refreshNetworkDecision()
            writePACCopy()
            if didRestartServers, let activeServerPorts {
                lastProxyMessage = "Local servers restarted: PAC \(activeServerPorts.pacHTTPPort), API \(activeServerPorts.apiHTTPPort), blocking proxy \(activeServerPorts.blockingHTTPProxyPort)"
            }
        } catch let error as PortConfigurationError {
            configurationValidationMessage = error.localizedDescription
            lastProxyMessage = error.localizedDescription
        } catch {
            lastProxyMessage = "Could not save configuration: \(error.localizedDescription)"
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
        configuration.profiles.remove(atOffsets: offsets)
        configuration.pacRules.removeAll { ids.contains($0.profileID) }
        saveConfiguration()
    }

    func addDisableRuleForCurrentNetwork() {
        refreshNetworkDecision()
        guard let rule = NetworkPolicyRule.disableProxyRule(from: currentNetworkFingerprint) else {
            lastProxyMessage = "Current network does not expose enough fingerprint data for a rule"
            return
        }
        configuration.networkRules.append(rule)
        saveConfiguration()
        lastProxyMessage = "Added network rule \(rule.name)"
    }

    func snapshot() -> AppStatusSnapshot {
        let profileStatuses = configuration.profiles.map { profile in
            ProfileStatusSnapshot(profile: profile, status: status(for: profile))
        }
        return AppStatusSnapshot(
            pacURL: pacURL,
            proxyDisabledByNetworkPolicy: networkDecision.shouldDisableProxy,
            matchedNetworkRule: networkDecision.matchedRule?.name,
            profiles: profileStatuses
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
            try startLocalServers(ports: LocalServerPorts(configuration: configuration))
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
        guard activeServerPorts != ports else { return false }
        let previousPorts = activeServerPorts
        stopLocalServers()

        do {
            try startLocalServers(ports: ports)
            return true
        } catch {
            stopLocalServers()
            if let previousPorts {
                try? startLocalServers(ports: previousPorts)
            }
            throw error
        }
    }

    private func startLocalServers(ports: LocalServerPorts) throws {
        let nextPACServer = LocalHTTPServer(port: ports.pacHTTPPort, label: "dev.clange.ssh-autotunnel.pac") { [weak self] request in
            self?.handlePACRequest(request) ?? .error(503, "Unavailable", "App state is unavailable")
        }
        try nextPACServer.start()

        let nextBlockingProxyServer = LocalHTTPServer(port: ports.blockingHTTPProxyPort, label: "dev.clange.ssh-autotunnel.blocking-proxy") { [weak self] request in
            self?.handleBlockingProxyRequest(request) ?? .error(503, "Unavailable", "App state is unavailable")
        }
        do {
            try nextBlockingProxyServer.start()
        } catch {
            nextPACServer.stop()
            throw error
        }

        let nextAPIServer = LocalHTTPServer(port: ports.apiHTTPPort, label: "dev.clange.ssh-autotunnel.api") { [weak self] request in
            self?.handleAPIRequest(request) ?? .error(503, "Unavailable", "App state is unavailable")
        }
        do {
            try nextAPIServer.start()
        } catch {
            nextPACServer.stop()
            nextBlockingProxyServer.stop()
            throw error
        }

        pacServer = nextPACServer
        blockingProxyServer = nextBlockingProxyServer
        apiServer = nextAPIServer
        activeServerPorts = ports
    }

    private func stopLocalServers() {
        pacServer?.stop()
        blockingProxyServer?.stop()
        apiServer?.stop()
        pacServer = nil
        blockingProxyServer = nil
        apiServer = nil
        activeServerPorts = nil
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
            guard request.headers["authorization"] == "Bearer \(configuration.apiToken)" else {
                return .error(401, "Unauthorized", "Missing or invalid API token")
            }
            if request.method == "GET", request.path.hasPrefix("/status") {
                return .json(ControlResponse(ok: true, message: "OK", status: snapshot()), encoder: jsonEncoder)
            }
            guard request.method == "POST", request.path.hasPrefix("/api") else {
                return .error(404, "Not Found", "Unknown API route")
            }
            do {
                let request = try jsonDecoder.decode(ControlRequest.self, from: request.body)
                let response = handleControlRequest(request)
                return .json(response, encoder: jsonEncoder)
            } catch {
                return .json(ControlResponse(ok: false, message: error.localizedDescription, status: snapshot()), encoder: jsonEncoder)
            }
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
            proxyDisabledByNetworkPolicy: networkDecision.shouldDisableProxy
        )
        return PACGenerator.generate(context: context)
    }

    private func writePACCopy() {
        do {
            try currentPAC().write(to: try AppPaths.pacCopyURL(), atomically: true, encoding: .utf8)
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

private struct LocalServerPorts: Equatable {
    var pacHTTPPort: Int
    var blockingHTTPProxyPort: Int
    var apiHTTPPort: Int

    init(configuration: AppConfiguration) {
        pacHTTPPort = configuration.pacHTTPPort
        blockingHTTPProxyPort = configuration.blockingHTTPProxyPort
        apiHTTPPort = configuration.apiHTTPPort
    }
}
