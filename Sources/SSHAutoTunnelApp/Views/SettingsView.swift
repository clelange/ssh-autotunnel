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
    @State private var sshConfigAuditReport: SSHConfigAuditReport?
    @State private var selectedSSHConfigFindingIDs: Set<String> = []
    @State private var sshConfigFixPreviews: [SSHConfigFileFixPreview] = []
    @State private var showsSSHConfigFixReview = false
    @State private var confirmsCommandLineToolInstall = false
    @State private var confirmsCommandLineToolUninstall = false

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
            UpdateSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.down.circle")
                }
            migrationTab
                .tabItem {
                    Label("Migration", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .padding(12)
        .frame(minWidth: 820, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .onChange(of: appState.configuration) {
            appState.scheduleConfigurationSave()
        }
        .onAppear {
            appState.refreshCommandLineToolInstallationStatus()
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
            Text("This writes ~/.ssh/config.d/ssh-autotunnel.conf and adds or reuses SSH AutoTunnel's marked Include block in ~/.ssh/config. Existing unmarked OpenSSH config blocks and system settings are not rewritten. Files changed during installation are backed up, including an older managed include before migration.")
        }
        .confirmationDialog(
            "Install ssh-autotunnelctl?",
            isPresented: $confirmsCommandLineToolInstall,
            titleVisibility: .visible
        ) {
            Button("Install Command Line Tool") {
                appState.installCommandLineTool()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates /usr/local/bin/ssh-autotunnelctl as a symbolic link to the helper embedded in /Applications/SSHAutoTunnel.app. macOS may request administrator approval.")
        }
        .confirmationDialog(
            "Uninstall ssh-autotunnelctl?",
            isPresented: $confirmsCommandLineToolUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall Command Line Tool", role: .destructive) {
                appState.uninstallCommandLineTool()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the managed symbolic link at /usr/local/bin/ssh-autotunnelctl. The embedded helper remains in the app and SSH AutoTunnel will continue to work normally.")
        }
        .sheet(isPresented: $showsSSHConfigFixReview) {
            SSHConfigFixReviewSheet(
                previews: sshConfigFixPreviews,
                onCancel: { showsSSHConfigFixReview = false },
                onApply: { applyReviewedSSHConfigFixes() }
            )
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
                    Text("API token")
                        .frame(width: 150, alignment: .leading)
                    SecureField("API token", text: $appState.configuration.apiToken)
                        .labelsHidden()
                        .accessibilityLabel("API token")
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

            Section("Command Line Tool") {
                LabeledContent("Status") {
                    Label(
                        appState.commandLineToolInstallationStatus.displayName,
                        systemImage: commandLineToolStatusSystemImage
                    )
                    .foregroundStyle(commandLineToolStatusColor)
                }
                Text(commandLineToolStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Install Command Line Tool…") {
                        confirmsCommandLineToolInstall = true
                    }
                    .disabled(!canInstallCommandLineTool)
                    Button("Uninstall Command Line Tool…", role: .destructive) {
                        confirmsCommandLineToolUninstall = true
                    }
                    .disabled(!canUninstallCommandLineTool)
                }
                if !appState.commandLineToolInstallationMessage.isEmpty {
                    Text(appState.commandLineToolInstallationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canInstallCommandLineTool: Bool {
        if case .notInstalled = appState.commandLineToolInstallationStatus {
            return true
        }
        return false
    }

    private var canUninstallCommandLineTool: Bool {
        if case .installed = appState.commandLineToolInstallationStatus {
            return true
        }
        return false
    }

    private var commandLineToolStatusSystemImage: String {
        switch appState.commandLineToolInstallationStatus {
        case .installed:
            "checkmark.circle.fill"
        case .notInstalled:
            "circle"
        case .unavailable:
            "exclamationmark.circle"
        case .conflict:
            "exclamationmark.triangle.fill"
        }
    }

    private var commandLineToolStatusColor: Color {
        switch appState.commandLineToolInstallationStatus {
        case .installed:
            .green
        case .notInstalled:
            .secondary
        case .unavailable, .conflict:
            .orange
        }
    }

    private var commandLineToolStatusDetail: String {
        switch appState.commandLineToolInstallationStatus {
        case .installed:
            "Terminal can find ssh-autotunnelctl at /usr/local/bin/ssh-autotunnelctl. The app continues to use its embedded helper directly."
        case .notInstalled:
            "Optional: install the embedded helper on your shell PATH. SSH AutoTunnel itself does not require this command to be installed."
        case .unavailable(let reason), .conflict(let reason):
            reason
        }
    }

    private var openSSHConfigTab: some View {
        Form {
            Section("Managed OpenSSH Adapter") {
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
                    Text("The managed include publishes readable adapters that attach to app-owned hop connections. It does not provide a direct fallback to the real hop server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let adapters = appState.managedHopAdapters()
                    if adapters.isEmpty {
                        Text("No internal hop adapter is available because no jump-host profile is configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(adapters, id: \.profileID) { adapter in
                            VStack(alignment: .leading, spacing: 2) {
                                CopyableValueRow(
                                    title: adapter.profileName,
                                    value: adapter.adapterHost,
                                    help: "Copy this readable alias for use as an existing ProxyJump target"
                                )
                                Text("Via \(adapter.endpoint.destination):\(adapter.endpoint.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Label(
                        "If the app-owned hop is disconnected, the app is quit, or the app is uninstalled, these aliases intentionally fail closed. Restore the original ProxyJump to connect directly through a hop server.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
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

            Section("Check SSH Config") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button {
                            runSSHConfigAudit()
                        } label: {
                            Label("Check SSH Config", systemImage: "checkmark.shield")
                        }
                        .help("Read ~/.ssh/config and included files, without executing Match exec")
                        if let report = sshConfigAuditReport {
                            Text("\(report.files.count) files · \(report.findings.count) findings · \(report.warnings.count) warnings")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let report = sshConfigAuditReport {
                        Label(
                            "Managed adapters: \(managedIntegrationLabel(report.managedIntegration.status))",
                            systemImage: report.managedIntegration.status == .current
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(report.managedIntegration.status == .current ? .green : .orange)
                        Text(report.managedIntegration.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("The audit follows Include files and recommends only evidence-based changes. It never adds routing based on a domain suffix or executes Match exec.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let report = sshConfigAuditReport {
                sshConfigFindingSection(
                    title: "Safe replacements",
                    findings: report.safeReplacements,
                    selectable: true
                )
                sshConfigFindingSection(
                    title: "Manual review",
                    findings: report.manualRecommendations,
                    selectable: false
                )
                sshConfigFindingSection(
                    title: "Information",
                    findings: report.information,
                    selectable: false
                )
                if !report.warnings.isEmpty {
                    Section("Audit warnings") {
                        ForEach(report.warnings) { warning in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(warningLocation(warning))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text(warning.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Reviewed application") {
                    Button("Review Selected Replacements...") {
                        reviewSelectedSSHConfigFixes()
                    }
                    .disabled(selectedSSHConfigFindingIDs.isEmpty)
                    Text("Only selected equivalent ProxyJump targets in eligible files can be applied. The next step shows complete per-file diffs; no API, CLI, or Shortcut can apply these edits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func sshConfigFindingSection(
        title: String,
        findings: [SSHConfigAuditFinding],
        selectable: Bool
    ) -> some View {
        Section(title) {
            if findings.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(findings) { finding in
                    if selectable && finding.canApply {
                        Toggle(
                            isOn: Binding(
                                get: { selectedSSHConfigFindingIDs.contains(finding.id) },
                                set: { selected in
                                    if selected {
                                        selectedSSHConfigFindingIDs.insert(finding.id)
                                    } else {
                                        selectedSSHConfigFindingIDs.remove(finding.id)
                                    }
                                }
                            )
                        ) {
                            sshConfigFindingDetails(finding)
                        }
                        .toggleStyle(.checkbox)
                    } else {
                        sshConfigFindingDetails(finding)
                        if selectable {
                            Text(sshConfigAuditReport?.managedIntegration.status == .current
                                ? "Recommendation only: this source file is not eligible for automatic editing."
                                : "Install or update the managed OpenSSH include before applying this replacement.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func sshConfigFindingDetails(_ finding: SSHConfigAuditFinding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(finding.title)
                .font(.callout.weight(.medium))
            Text("\(finding.location.path):\(finding.location.line)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(finding.reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !finding.context.isEmpty {
                Text(finding.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(finding.beforeText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let afterText = finding.afterText {
                Text("→ \(afterText)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
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
            LabeledContent("Existing PAC file") {
                HStack {
                    TextField("Existing PAC file", text: $appState.configuration.pacAppendSource.location)
                        .labelsHidden()
                        .accessibilityLabel("Existing PAC file")
                        .help("Local PAC file to append after SSH AutoTunnel's generated rules.")
                    Button("Choose...") {
                        choosePACFile()
                    }
                    .help("Choose a PAC file path")
                }
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
            let migrationBackupStatus = result.managedConfigBackupURL.map { " Managed-config migration backup: \($0.path)" } ?? ""
            sshConfigMessage = "Installed \(result.managedConfigURL.path), \(includeStatus).\(backupStatus)\(migrationBackupStatus)"
            sshConfigAuditReport = appState.checkSSHConfig()
            selectedSSHConfigFindingIDs.removeAll()
            sshConfigFixPreviews.removeAll()
        } catch {
            sshConfigMessage = "Could not install managed OpenSSH config: \(error.localizedDescription)"
        }
    }

    private func managedIntegrationLabel(_ status: SSHConfigManagedIntegrationStatus) -> String {
        switch status {
        case .current: "Current"
        case .notInstalled: "Not installed"
        case .updateRequired: "Update required"
        case .conflict: "Conflict"
        }
    }

    private func runSSHConfigAudit() {
        let report = appState.checkSSHConfig()
        sshConfigAuditReport = report
        selectedSSHConfigFindingIDs.removeAll()
        sshConfigFixPreviews.removeAll()
        sshConfigMessage = "SSH config audit found \(report.safeReplacements.count) safe replacement(s), \(report.manualRecommendations.count) manual recommendation(s), and \(report.warnings.count) warning(s)."
    }

    private func reviewSelectedSSHConfigFixes() {
        guard let report = sshConfigAuditReport else { return }
        do {
            sshConfigFixPreviews = try appState.previewSSHConfigSafeFixes(
                report: report,
                findingIDs: selectedSSHConfigFindingIDs
            )
            guard !sshConfigFixPreviews.isEmpty else {
                sshConfigMessage = "No eligible SSH config replacements are selected."
                return
            }
            showsSSHConfigFixReview = true
        } catch {
            sshConfigMessage = error.localizedDescription
        }
    }

    private func applyReviewedSSHConfigFixes() {
        guard let report = sshConfigAuditReport else { return }
        do {
            let result = try appState.applySSHConfigSafeFixes(
                report: report,
                findingIDs: selectedSSHConfigFindingIDs
            )
            showsSSHConfigFixReview = false
            let backups = result.backupPaths.isEmpty ? "" : " Backups: \(result.backupPaths.joined(separator: ", "))"
            sshConfigMessage = "Applied \(result.appliedFindingIDs.count) reviewed replacement(s) in \(result.changedFiles.count) file(s).\(backups)"
            sshConfigAuditReport = appState.checkSSHConfig()
            selectedSSHConfigFindingIDs.removeAll()
            sshConfigFixPreviews.removeAll()
        } catch {
            showsSSHConfigFixReview = false
            sshConfigMessage = error.localizedDescription
        }
    }

    private func warningLocation(_ warning: SSHConfigAuditWarning) -> String {
        warning.line.map { "\(warning.path):\($0)" } ?? warning.path
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

private struct SSHConfigFixReviewSheet: View {
    let previews: [SSHConfigFileFixPreview]
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review SSH Config Replacements")
                .font(.title2.weight(.semibold))
            Text("Complete diffs are shown below. Applying creates private timestamped backups, then rechecks every file's content and metadata before writing atomically.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, preview in
                        GroupBox(preview.path) {
                            ScrollView(.horizontal) {
                                Text(preview.unifiedDiff)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply Reviewed Replacements", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
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
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, value: $value, format: .number)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .frame(width: 90)
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
