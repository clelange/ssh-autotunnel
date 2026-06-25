import AppKit
import SSHAutoTunnelCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var configurationFileMessage = ""
    @State private var apiTokenMessage = ""
    @State private var sshConfigMessage = ""
    @State private var confirmsManagedSSHConfigInstall = false

    var body: some View {
        TabView {
            pacTab
                .tabItem {
                    Label("PAC", systemImage: "network")
                }
            localAPITab
                .tabItem {
                    Label("Local API", systemImage: "terminal")
                }
            openSSHConfigTab
                .tabItem {
                    Label("OpenSSH", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            migrationTab
                .tabItem {
                    Label("Migration", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .padding(12)
        .frame(minWidth: 640, idealWidth: 640, minHeight: 460, idealHeight: 460)
        .onChange(of: appState.configuration) {
            appState.scheduleConfigurationSave()
        }
        .confirmationDialog(
            "Install SSH AutoTunnel managed OpenSSH config?",
            isPresented: $confirmsManagedSSHConfigInstall,
            titleVisibility: .visible
        ) {
            Button("Install Include") {
                installManagedSSHConfig()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes ~/.ssh/config.d/ssh-autotunnel.conf and adds or reuses SSH AutoTunnel's marked Include block in ~/.ssh/config. Existing unmarked OpenSSH config blocks and system settings are not rewritten. If ~/.ssh/config already exists and the Include block must be added, a backup is created first.")
        }
    }

    private var pacTab: some View {
        Form {
            Section("Status") {
                SystemPACStatusDetailView()
                CopyableValueRow(
                    title: "Configured PAC URL",
                    value: appState.configuredPACURL,
                    help: "Copy the PAC URL that matches the configured PAC HTTP port"
                )
                if appState.activePACURL != appState.configuredPACURL {
                    CopyableValueRow(
                        title: "Active PAC URL",
                        value: appState.activePACURL,
                        help: "Copy the PAC URL served by the currently running listener"
                    )
                    Text("The running PAC listener is still using the previous port. It will move to the configured port after the configuration is saved and local servers restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Local Service Ports") {
                PortField(
                    title: "PAC HTTP port",
                    value: $appState.configuration.pacHTTPPort,
                    defaultValue: SettingsPortDefaults.pacHTTP,
                    help: "Loopback HTTP port that serves the PAC file and local status page."
                )
                PortField(
                    title: "Blocking proxy port",
                    value: $appState.configuration.blockingHTTPProxyPort,
                    defaultValue: SettingsPortDefaults.blockingHTTPProxy,
                    help: "Loopback HTTP proxy used by fail-closed PAC rules when a matching destination should be blocked instead of sent directly."
                )
                resetAllPortsButton
                configurationValidationNotice
            }

            Section("PAC Composition") {
                Toggle("Append existing PAC", isOn: $appState.configuration.pacAppendSource.enabled)
                    .help("Append another PAC file after SSH AutoTunnel's generated rules.")
                Picker("Existing PAC source", selection: $appState.configuration.pacAppendSource.kind) {
                    ForEach(PACAppendSourceKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(!appState.configuration.pacAppendSource.enabled)
                .help("Choose whether the appended PAC is loaded from an HTTP(S) URL or a local file.")
                pacAppendSourceLocationField
                HStack {
                    Button("Reload Existing PAC") {
                        appState.refreshPACAppendSource(force: true)
                    }
                    .disabled(!appState.configuration.pacAppendSource.isReadyToLoad)
                    .help("Reload the configured PAC source")
                    Text(appState.pacAppendSourceMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("System Proxy") {
                Picker("System proxy", selection: $appState.configuration.proxyApplyMode) {
                    Text("Manual").tag(ProxyApplyMode.manual)
                    Text("Apply to active service").tag(ProxyApplyMode.activeNetworkServicePAC)
                }
                .help("Choose whether SSH AutoTunnel should manage macOS Automatic Proxy Configuration for the active network service.")
                HStack {
                    Button("Apply System PAC Now") {
                        appState.applySystemPAC()
                    }
                    .help("Apply the configured SSH AutoTunnel PAC URL to the active network service.")
                    Button("Restore Previous System Proxy") {
                        appState.restoreSystemPAC()
                    }
                    .help("Restore the proxy settings saved before SSH AutoTunnel applied its PAC URL.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var localAPITab: some View {
        Form {
            Section("Local API") {
                CopyableValueRow(
                    title: "Configured API URL",
                    value: appState.configuredAPIURL,
                    help: "Copy the local API URL that matches the configured API HTTP port"
                )
                if appState.activeAPIURL != appState.configuredAPIURL {
                    CopyableValueRow(
                        title: "Active API URL",
                        value: appState.activeAPIURL,
                        help: "Copy the local API URL served by the currently running listener"
                    )
                    Text("The running API listener is still using the previous port. It will move to the configured port after the configuration is saved and local servers restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PortField(
                    title: "API HTTP port",
                    value: $appState.configuration.apiHTTPPort,
                    defaultValue: SettingsPortDefaults.apiHTTP,
                    help: "Loopback HTTP port used by ssh-autotunnelctl, Shortcuts actions, and local automation."
                )
                resetAllPortsButton
                configurationValidationNotice
                HStack {
                    SecureField("API token", text: $appState.configuration.apiToken)
                        .help("Token required by local API clients. The server only listens on loopback.")
                    Button {
                        copyAPIToken()
                    } label: {
                        Label("Copy API Token", systemImage: "doc.on.doc")
                    }
                    .help("Copy the current API token")
                }
                Button("Rotate API Token") {
                    appState.rotateAPIToken()
                    apiTokenMessage = "Rotated API token"
                }
                .help("Create a new local API token")
                if !apiTokenMessage.isEmpty {
                    Text(apiTokenMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var openSSHConfigTab: some View {
        Form {
            Section("OpenSSH Config") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            copyManagedSSHConfigSnippet()
                        } label: {
                            Label("Copy Managed Snippet", systemImage: "doc.on.doc")
                        }
                        .help("Copy managed SSH config snippet")
                        Button {
                            confirmsManagedSSHConfigInstall = true
                        } label: {
                            Label("Install Include...", systemImage: "square.and.arrow.down")
                        }
                        .help("Write SSH AutoTunnel's managed OpenSSH include file and add a marked Include block to ~/.ssh/config when needed.")
                    }
                    Text("The managed include is limited to SSH AutoTunnel jump-host profile entries. Installation writes a separate managed file and only adds a marked Include block to your main OpenSSH config when that block is missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(managedSSHConfigPreview())
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                    if !sshConfigMessage.isEmpty {
                        Text(sshConfigMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var migrationTab: some View {
        Form {
            Section("Migration") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Export Configuration...") {
                            exportConfiguration()
                        }
                        Button("Validate Configuration...") {
                            validateConfiguration()
                        }
                    }
                    HStack {
                        Button("Import Configuration...") {
                            importConfiguration()
                        }
                        Button("Create Support Bundle...") {
                            createSupportBundle()
                        }
                    }
                    if !configurationFileMessage.isEmpty {
                        Text(configurationFileMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Check ssh-auto2fa Services") {
                        appState.refreshSSHAuto2FAServiceStatuses()
                    }
                    Button("Import ssh-auto2fa Presets") {
                        appState.importSSHAuto2FAPresets()
                    }
                    Button("Import SSH Config") {
                        do {
                            try appState.importSSHConfig()
                        } catch {
                            appState.lastProxyMessage = "Could not import SSH config: \(error.localizedDescription)"
                        }
                    }
                }
                if !appState.sshAuto2FAServiceStatuses.isEmpty {
                    ForEach(appState.sshAuto2FAServiceStatuses) { status in
                        HStack {
                            Text(status.requirement.profileName)
                            Text(status.requirement.kind.displayName)
                                .foregroundStyle(.secondary)
                            Text(status.requirement.service)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(status.requirement.account)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            Text(keychainStatusLabel(status.state))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                Text("Imports legacy ssh-auto2fa CERN and PSI Tier-3 service names, or imports literal hosts from ~/.ssh/config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var pacAppendSourceLocationField: some View {
        if appState.configuration.pacAppendSource.kind == .url {
            TextField("Existing PAC URL", text: $appState.configuration.pacAppendSource.location)
                .disabled(!appState.configuration.pacAppendSource.enabled)
                .help("HTTP(S) PAC URL to append after SSH AutoTunnel's generated rules.")
        } else {
            HStack {
                TextField("Existing PAC file", text: $appState.configuration.pacAppendSource.location)
                    .help("Local PAC file to append after SSH AutoTunnel's generated rules.")
                Button("Choose...") {
                    choosePACFile()
                }
                .help("Choose a PAC file path")
            }
            .disabled(!appState.configuration.pacAppendSource.enabled)
        }
    }

    @ViewBuilder
    private var configurationValidationNotice: some View {
        if let message = appState.configurationValidationMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var resetAllPortsButton: some View {
        Button {
            resetAllLocalServicePorts()
        } label: {
            Label("Reset All Ports to Defaults", systemImage: "arrow.counterclockwise")
        }
        .disabled(usesDefaultLocalServicePorts)
        .help("Restore PAC HTTP \(SettingsPortDefaults.pacHTTP), API HTTP \(SettingsPortDefaults.apiHTTP), and blocking proxy \(SettingsPortDefaults.blockingHTTPProxy).")
    }

    private var usesDefaultLocalServicePorts: Bool {
        appState.configuration.pacHTTPPort == SettingsPortDefaults.pacHTTP &&
            appState.configuration.apiHTTPPort == SettingsPortDefaults.apiHTTP &&
            appState.configuration.blockingHTTPProxyPort == SettingsPortDefaults.blockingHTTPProxy
    }

    private func keychainStatusLabel(_ state: KeychainCredentialState) -> String {
        switch state {
        case .available: "Found"
        case .missing: "Missing"
        case .unreadable: "Unreadable"
        }
    }

    private func resetAllLocalServicePorts() {
        appState.configuration.pacHTTPPort = SettingsPortDefaults.pacHTTP
        appState.configuration.apiHTTPPort = SettingsPortDefaults.apiHTTP
        appState.configuration.blockingHTTPProxyPort = SettingsPortDefaults.blockingHTTPProxy
    }

    private func copyAPIToken() {
        copyToPasteboard(appState.configuration.apiToken)
        apiTokenMessage = "Copied API token"
    }

    private func copyManagedSSHConfigSnippet() {
        do {
            let snippet = try appState.managedSSHConfigSnippet()
            copyToPasteboard(snippet)
            sshConfigMessage = "Copied managed OpenSSH config snippet"
        } catch {
            sshConfigMessage = "Could not copy managed OpenSSH config: \(error.localizedDescription)"
        }
    }

    private func installManagedSSHConfig() {
        do {
            let result = try appState.installManagedSSHConfig()
            let includeStatus = result.updatedMainConfig ? "added include" : "include already present"
            let backupStatus = result.backupURL.map { " Backup: \($0.path)" } ?? ""
            sshConfigMessage = "Installed \(result.managedConfigURL.path), \(includeStatus).\(backupStatus)"
        } catch {
            sshConfigMessage = "Could not install managed OpenSSH config: \(error.localizedDescription)"
        }
    }

    private func managedSSHConfigPreview() -> String {
        do {
            return try appState.managedSSHConfigSnippet()
        } catch {
            return "Could not render managed OpenSSH config: \(error.localizedDescription)"
        }
    }

    private func exportConfiguration() {
        guard let url = saveURL(defaultFileName: "ssh-autotunnel-config.json") else { return }
        do {
            try writeJSON(appState.configurationExport(), to: url)
            configurationFileMessage = "Exported configuration to \(url.path)"
        } catch {
            configurationFileMessage = "Could not export configuration: \(error.localizedDescription)"
        }
    }

    private func validateConfiguration() {
        guard let url = openURL() else { return }
        do {
            let export = try readConfigurationExport(from: url)
            let report = appState.configurationValidationReport(for: export)
            configurationFileMessage = validationMessage(report)
        } catch {
            configurationFileMessage = "Could not validate configuration: \(error.localizedDescription)"
        }
    }

    private func importConfiguration() {
        guard let url = openURL() else { return }
        do {
            let export = try readConfigurationExport(from: url)
            let report = appState.configurationValidationReport(for: export)
            guard report.ok else {
                configurationFileMessage = validationMessage(report)
                return
            }
            guard confirmImport(report) else {
                configurationFileMessage = "Import canceled"
                return
            }
            let response = appState.importConfigurationExport(export)
            configurationFileMessage = response.message
        } catch {
            configurationFileMessage = "Could not import configuration: \(error.localizedDescription)"
        }
    }

    private func createSupportBundle() {
        guard let url = saveURL(defaultFileName: "ssh-autotunnel-support.json") else { return }
        do {
            try writeJSON(appState.supportBundle(), to: url)
            configurationFileMessage = "Created support bundle at \(url.path)"
        } catch {
            configurationFileMessage = "Could not create support bundle: \(error.localizedDescription)"
        }
    }

    private func saveURL(defaultFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultFileName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func choosePACFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.configuration.pacAppendSource.kind = .file
        appState.configuration.pacAppendSource.location = url.path
        appState.saveConfiguration()
        appState.refreshPACAppendSource(force: true)
    }

    private func openURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func readConfigurationExport(from url: URL) throws -> ConfigurationExport {
        let data = try Data(contentsOf: url)
        return try ConfigurationExportService.decodeExportDocument(from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try data.write(to: url, options: [.atomic])
        try FileProtection.protectFile(url)
    }

    private func validationMessage(_ report: ConfigurationValidationReport) -> String {
        let warningSuffix = report.warnings.isEmpty ? "" : " Warnings: \(report.warnings.joined(separator: "; "))"
        if report.ok {
            return "Configuration is valid: \(report.profileCount) profiles, \(report.pacRuleCount) PAC rules, \(report.networkRuleCount) network rules.\(warningSuffix)"
        }
        let details = report.messages.isEmpty ? report.message : report.messages.joined(separator: "; ")
        return "Configuration is invalid: \(details).\(warningSuffix)"
    }

    private func confirmImport(_ report: ConfigurationValidationReport) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Import Configuration?"
        let warningText = report.warnings.isEmpty ? "" : "\n\nWarnings:\n\(report.warnings.joined(separator: "\n"))"
        alert.informativeText = "This will replace the current profiles and rules with \(report.profileCount) profiles, \(report.pacRuleCount) PAC rules, and \(report.networkRuleCount) network rules. A private pre-import backup will be created first.\(warningText)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum SettingsPortDefaults {
    static let pacHTTP = 18_483
    static let apiHTTP = 18_484
    static let blockingHTTPProxy = 18_485
}

private struct PortField: View {
    var title: String
    @Binding var value: Int
    var defaultValue: Int
    var help: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(title, value: $value, format: .number)
                .frame(width: 190)
                .help(help)
            Stepper("Adjust \(title)", value: $value, in: PortConfigurationValidator.validRange)
                .labelsHidden()
                .help(help)
            Button {
                value = defaultValue
            } label: {
                Label("Reset \(title)", systemImage: "arrow.counterclockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(value == defaultValue)
            .opacity(value == defaultValue ? 0 : 1)
            .help("Reset \(title) to \(defaultValue)")
        }
    }
}

private struct CopyableValueRow: View {
    var title: String
    var value: String
    var help: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Label("Copy \(title)", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(help)
        }
    }
}
