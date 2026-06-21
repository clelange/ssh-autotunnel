import AppKit
import SSHAutoTunnelCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var configurationFileMessage = ""
    @State private var sshConfigMessage = ""
    @State private var confirmsManagedSSHConfigInstall = false

    var body: some View {
        Form {
            Section("PAC") {
                SystemPACStatusDetailView()
                Text(appState.pacURL)
                    .textSelection(.enabled)
                TextField("PAC HTTP port", value: $appState.configuration.pacHTTPPort, format: .number)
                TextField("Blocking proxy port", value: $appState.configuration.blockingHTTPProxyPort, format: .number)
                Toggle("Append existing PAC", isOn: $appState.configuration.pacAppendSource.enabled)
                Picker("Existing PAC source", selection: $appState.configuration.pacAppendSource.kind) {
                    ForEach(PACAppendSourceKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(!appState.configuration.pacAppendSource.enabled)
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
                if let message = appState.configurationValidationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("System proxy", selection: $appState.configuration.proxyApplyMode) {
                    Text("Manual").tag(ProxyApplyMode.manual)
                    Text("Apply to active service").tag(ProxyApplyMode.activeNetworkServicePAC)
                }
                Button("Apply System PAC Now") {
                    appState.applySystemPAC()
                }
                .help("Apply PAC to active network service")
                Button("Restore Previous System Proxy") {
                    appState.restoreSystemPAC()
                }
                .help("Restore previous system proxy settings")
            }

            Section("Local API") {
                Text("http://127.0.0.1:\(appState.configuration.apiHTTPPort)")
                    .textSelection(.enabled)
                TextField("API HTTP port", value: $appState.configuration.apiHTTPPort, format: .number)
                SecureField("API token", text: $appState.configuration.apiToken)
                Button("Rotate API Token") {
                    appState.rotateAPIToken()
                }
                .help("Create a new local API token")
            }

            Section("Interactive SSH") {
                InteractiveTerminalPreferenceControl(style: .settings)
            }

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
                            Label("Install Managed Include...", systemImage: "square.and.arrow.down")
                        }
                        .help("Install managed SSH include configuration")
                    }
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
        .padding()
        .frame(minWidth: 640, minHeight: 620)
        .onChange(of: appState.configuration) {
            appState.scheduleConfigurationSave()
        }
        .confirmationDialog(
            "Install SSH AutoTunnel managed OpenSSH config?",
            isPresented: $confirmsManagedSSHConfigInstall,
            titleVisibility: .visible
        ) {
            Button("Install Managed Include") {
                installManagedSSHConfig()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes ~/.ssh/config.d/ssh-autotunnel.conf and adds a marked Include block to ~/.ssh/config. Existing SSH config blocks are not edited.")
        }
    }

    @ViewBuilder
    private var pacAppendSourceLocationField: some View {
        if appState.configuration.pacAppendSource.kind == .url {
            TextField("Existing PAC URL", text: $appState.configuration.pacAppendSource.location)
                .disabled(!appState.configuration.pacAppendSource.enabled)
        } else {
            HStack {
                TextField("Existing PAC file", text: $appState.configuration.pacAppendSource.location)
                Button("Choose...") {
                    choosePACFile()
                }
                .help("Choose a PAC file path")
            }
            .disabled(!appState.configuration.pacAppendSource.enabled)
        }
    }

    private func keychainStatusLabel(_ state: KeychainCredentialState) -> String {
        switch state {
        case .available: "Found"
        case .missing: "Missing"
        case .unreadable: "Unreadable"
        }
    }

    private func copyManagedSSHConfigSnippet() {
        do {
            let snippet = try appState.managedSSHConfigSnippet()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet, forType: .string)
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
}
