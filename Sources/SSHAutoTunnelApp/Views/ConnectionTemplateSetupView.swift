import SSHAutoTunnelCore
import SwiftUI

private enum ConnectionTemplateSetupStep: Int, CaseIterable, Identifiable {
    case template
    case credentials
    case tunnel
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .template: "Template"
        case .credentials: "Credentials"
        case .tunnel: "Tunnel"
        case .review: "Review"
        }
    }

    var next: ConnectionTemplateSetupStep? {
        ConnectionTemplateSetupStep(rawValue: rawValue + 1)
    }

    var previous: ConnectionTemplateSetupStep? {
        ConnectionTemplateSetupStep(rawValue: rawValue - 1)
    }
}

struct ConnectionTemplateSetupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var step: ConnectionTemplateSetupStep = .template
    @State private var selectedTemplateID: AccountPresetID = AccountSetupService.templates[0].id
    @State private var input = AccountSetupInput(
        id: AccountSetupService.templates[0].id,
        useForTunnelling: AccountSetupService.templates[0].defaultTunnelEnabled,
        tunnelHost: AccountSetupService.templates[0].defaultTunnelHost
    )
    @State private var credentialStatus: AccountSetupCredentialStatus?
    @State private var password = ""
    @State private var totpSeed = ""
    @State private var setupMessage: String?

    private var selectedTemplate: ConnectionTemplate {
        AccountSetupService.template(for: selectedTemplateID) ?? AccountSetupService.templates[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Picker("Step", selection: $step) {
                ForEach(ConnectionTemplateSetupStep.allCases) { step in
                    Text(step.title).tag(step)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .template:
                        templateStep
                    case .credentials:
                        credentialsStep
                    case .tunnel:
                        tunnelStep
                    case .review:
                        reviewStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let setupMessage {
                Text(setupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            footer
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 620)
        .onAppear {
            loadTemplate(selectedTemplateID)
        }
        .onChange(of: selectedTemplateID) { _, newValue in
            loadTemplate(newValue)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("New Connection", systemImage: "plus.circle")
                .font(.title2)
            Spacer()
            Button {
                openWindow(id: "settings")
                AppActivation.activate()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open app settings")
        }
    }

    private var templateStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AccountSetupService.templates) { template in
                ConnectionTemplateSelectionRow(
                    template: template,
                    isSelected: selectedTemplateID == template.id
                ) {
                    selectedTemplateID = template.id
                }
            }
        }
    }

    private var credentialsStep: some View {
        TemplateCredentialView(
            template: selectedTemplate,
            input: $input,
            status: credentialStatus,
            password: $password,
            totpSeed: $totpSeed,
            refreshStatus: refreshCredentialStatus
        )
    }

    private var tunnelStep: some View {
        TemplateTunnelView(template: selectedTemplate, input: $input)
    }

    private var reviewStep: some View {
        ConnectionTemplateReviewView(
            template: selectedTemplate,
            input: resolvedInput,
            configuration: appState.configuration
        )
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            Spacer()
            Button("Back") {
                if let previous = step.previous {
                    step = previous
                }
            }
            .disabled(step.previous == nil)

            if step == .review {
                Button("Save") {
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") {
                    advance()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var resolvedInput: AccountSetupInput {
        var resolved = input
        resolved.isSelected = true
        resolved.passwordAvailable = passwordAvailable
        resolved.totpSeedAvailable = totpSeedAvailable
        return resolved
    }

    private var passwordAvailable: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || credentialStatus?.passwordState == .available
    }

    private var totpSeedAvailable: Bool {
        !totpSeed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || credentialStatus?.totpSeedState == .available
    }

    private func loadTemplate(_ templateID: AccountPresetID) {
        input = appState.defaultConnectionTemplateSetupInput(for: templateID)
        input.isSelected = true
        password = ""
        totpSeed = ""
        setupMessage = nil
        refreshCredentialStatus()
    }

    private func advance() {
        if step == .template || step == .credentials {
            refreshCredentialStatus()
        }
        if let next = step.next {
            step = next
        }
    }

    private func refreshCredentialStatus() {
        credentialStatus = appState.accountSetupCredentialStatus(for: input)
        input.passwordAvailable = passwordAvailable
        input.totpSeedAvailable = totpSeedAvailable
    }

    private func finish() {
        do {
            _ = try appState.applyConnectionTemplateSetup(
                input: resolvedInput,
                password: password,
                totpSeed: totpSeed
            )
            dismiss()
        } catch {
            setupMessage = error.localizedDescription
            if let setupError = error as? AccountSetupError {
                switch setupError {
                case .missingUsername, .missingPassword:
                    step = .credentials
                case .missingTunnelHost:
                    step = .tunnel
                case .unknownPreset:
                    step = .template
                }
            }
        }
    }
}

private struct ConnectionTemplateSelectionRow: View {
    var template: ConnectionTemplate
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(template.displayName)
                            .font(.headline)
                        Spacer()
                        HelpLinksView(urls: template.helpURLs)
                    }

                    KeyValueGrid(rows: rows)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(isSelected ? 0.55 : 0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 1 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var rows: [KeyValueRow] {
        var values = [
            KeyValueRow("Credential Host", template.credentialHost),
            KeyValueRow("Default Server", template.defaultTunnelHost.isEmpty ? "Set during setup" : template.defaultTunnelHost)
        ]
        if let interactiveHost = template.interactiveHost {
            values.append(KeyValueRow("Interactive Host", interactiveHost))
        }
        if let jumpHostFormat = template.jumpHostFormat {
            values.append(KeyValueRow("Bastion", jumpHostFormat.replacingOccurrences(of: "{username}", with: "username")))
        }
        return values
    }
}

private struct TemplateCredentialView: View {
    var template: ConnectionTemplate
    @Binding var input: AccountSetupInput
    var status: AccountSetupCredentialStatus?
    @Binding var password: String
    @Binding var totpSeed: String
    var refreshStatus: () -> Void

    var body: some View {
        SectionPanel(title: "Credentials", systemImage: "key") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(template.displayName)
                        .font(.headline)
                    Spacer()
                    CredentialStatusLabel(title: "Password", state: passwordState)
                    CredentialStatusLabel(title: "TOTP", state: totpState)
                    Button {
                        refreshStatus()
                    } label: {
                        Label("Check Keychain", systemImage: "key.viewfinder")
                    }
                    .help("Refresh credential status from Keychain")
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Username")
                            .foregroundStyle(.secondary)
                        TextField("Username", text: $input.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Credential Host")
                            .foregroundStyle(.secondary)
                        Text(template.credentialHost)
                            .textSelection(.enabled)
                    }
                    if passwordState != .available {
                        GridRow {
                            Text("Password")
                                .foregroundStyle(.secondary)
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    if totpState != .available {
                        GridRow {
                            Text("TOTP Seed")
                                .foregroundStyle(.secondary)
                            SecureField("Optional", text: $totpSeed)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        Text("Keychain Account")
                            .foregroundStyle(.secondary)
                        Text(input.username)
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var passwordState: KeychainCredentialState {
        if !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .available
        }
        return status?.passwordState ?? .missing
    }

    private var totpState: KeychainCredentialState {
        if !totpSeed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .available
        }
        return status?.totpSeedState ?? .missing
    }
}

private struct TemplateTunnelView: View {
    var template: ConnectionTemplate
    @Binding var input: AccountSetupInput

    var body: some View {
        SectionPanel(title: "Tunnel", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $input.useForTunnelling) {
                    Text("Create Tunnel Profile")
                        .font(.headline)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Profile")
                            .foregroundStyle(.secondary)
                        Text(template.profileName)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Final Server")
                            .foregroundStyle(.secondary)
                        EditableSuggestionField(
                            placeholder: "Server",
                            text: $input.tunnelHost,
                            suggestions: template.suggestedTunnelHosts
                        )
                        .disabled(!input.useForTunnelling)
                    }
                    if let interactiveHost = resolvedInteractiveHost {
                        GridRow {
                            Text("Interactive Host")
                                .foregroundStyle(.secondary)
                            Text(interactiveHost)
                                .textSelection(.enabled)
                        }
                    }
                    if let jumpHost = template.jumpHost(username: input.username.trimmingCharacters(in: .whitespacesAndNewlines)), input.useForTunnelling {
                        GridRow {
                            Text("Bastion")
                                .foregroundStyle(.secondary)
                            Text(jumpHost)
                                .textSelection(.enabled)
                        }
                    }
                    if let pattern = template.pacDomainPattern(tunnelHost: input.tunnelHost), input.useForTunnelling {
                        GridRow {
                            Text("PAC Rule")
                                .foregroundStyle(.secondary)
                            Text(pattern)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var resolvedInteractiveHost: String? {
        if let interactiveHost = template.interactiveHost?.trimmingCharacters(in: .whitespacesAndNewlines), !interactiveHost.isEmpty {
            return interactiveHost
        }
        let tunnelHost = input.tunnelHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return tunnelHost.isEmpty ? nil : tunnelHost
    }
}

private struct ConnectionTemplateReviewView: View {
    var template: ConnectionTemplate
    var input: AccountSetupInput
    var configuration: AppConfiguration

    var body: some View {
        SectionPanel(title: "Review", systemImage: "checklist") {
            KeyValueGrid(rows: rows)
        }
    }

    private var rows: [KeyValueRow] {
        var values = [
            KeyValueRow("Template", template.displayName),
            KeyValueRow("Username", input.username.trimmingCharacters(in: .whitespacesAndNewlines)),
            KeyValueRow("Password", input.passwordAvailable ? "Available" : "Missing"),
            KeyValueRow("TOTP Seed", input.totpSeedAvailable ? "Available" : "Not configured")
        ]

        guard input.useForTunnelling else {
            values.append(KeyValueRow("Tunnel", "Credentials only"))
            return values
        }

        values.append(contentsOf: [
            KeyValueRow("Profile", template.profileName),
            KeyValueRow("Final Server", input.tunnelHost.trimmingCharacters(in: .whitespacesAndNewlines)),
            KeyValueRow("SOCKS Port", "\(resolvedLocalSocksPort)")
        ])

        if let jumpHost = template.jumpHost(username: input.username.trimmingCharacters(in: .whitespacesAndNewlines)) {
            values.append(KeyValueRow("Bastion", jumpHost))
        }
        if let pacRule = template.pacDomainPattern(tunnelHost: input.tunnelHost) {
            values.append(KeyValueRow("PAC Rule", "\(template.pacRuleName): \(pacRule)"))
        }
        return values
    }

    private var resolvedLocalSocksPort: Int {
        if let existing = configuration.profiles.first(where: { $0.name == template.profileName }) {
            return existing.localSocksPort
        }
        let usedPorts = Set(configuration.profiles.map(\.localSocksPort))
        var port = template.defaultLocalSocksPort
        while usedPorts.contains(port) {
            port += 1
        }
        return port
    }
}

private struct EditableSuggestionField: View {
    var placeholder: String
    @Binding var text: String
    var suggestions: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)

            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            text = suggestion
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .help("Choose a suggested server")
            }
        }
    }
}

private struct CredentialStatusLabel: View {
    var title: String
    var state: KeychainCredentialState

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch state {
        case .available: "checkmark.circle.fill"
        case .missing: "questionmark.circle"
        case .unreadable: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .available: .green
        case .missing: .secondary
        case .unreadable: .orange
        }
    }
}

private struct HelpLinksView: View {
    var urls: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, rawURL in
                if let url = URL(string: rawURL) {
                    Link(destination: url) {
                        Label("Info \(index + 1)", systemImage: "questionmark.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help(rawURL)
                }
            }
        }
    }
}
