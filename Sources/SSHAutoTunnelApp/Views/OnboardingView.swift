import AppKit
import SSHAutoTunnelCore
import SwiftUI

private let onboardingCompletedKey = "dev.clange.ssh-autotunnel.onboardingCompleted"

struct OnboardingPresenter: View {
    @AppStorage(onboardingCompletedKey) private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @State private var didPresent = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                presentIfNeeded()
            }
    }

    private func presentIfNeeded() {
        guard !hasCompletedOnboarding, !didPresent else { return }
        didPresent = true
        openWindow(id: "onboarding")
        AppActivation.activate()
    }
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case accounts
    case credentials
    case tunnels
    case summary

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .credentials: "Credentials"
        case .tunnels: "Tunnels"
        case .summary: "Summary"
        }
    }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage(onboardingCompletedKey) private var hasCompletedOnboarding = false
    @State private var step: OnboardingStep = .accounts
    @State private var inputs: [AccountSetupInput] = []
    @State private var credentialStatuses: [AccountPresetID: AccountSetupCredentialStatus] = [:]
    @State private var passwords: [AccountPresetID: String] = [:]
    @State private var totpSeeds: [AccountPresetID: String] = [:]
    @State private var setupMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label("SSH AutoTunnel Setup", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                Spacer()
                Button {
                    openWindow(id: "settings")
                    AppActivation.activate()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            Picker("Step", selection: $step) {
                ForEach(OnboardingStep.allCases) { step in
                    Text(step.title).tag(step)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .accounts:
                        accountsStep
                    case .credentials:
                        credentialsStep
                    case .tunnels:
                        tunnelsStep
                    case .summary:
                        summaryStep
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

            HStack {
                Button("Later") {
                    dismiss()
                }
                Button("Skip All") {
                    finish(inputs.map { input in
                        var copy = input
                        copy.isSelected = false
                        return copy
                    })
                }
                Spacer()
                Button("Back") {
                    if let previous = step.previous {
                        step = previous
                    }
                }
                .disabled(step.previous == nil)
                if step == .summary {
                    Button("Finish") {
                        finish(inputs)
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
        .padding(28)
        .frame(minWidth: 760, minHeight: 620)
        .background(SetupWindowLevelConfigurator())
        .onAppear {
            loadInputsIfNeeded()
        }
    }

    private var selectedInputs: [AccountSetupInput] {
        inputs.filter(\.isSelected)
    }

    private var accountsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AccountSetupService.presets) { preset in
                if let index = inputs.firstIndex(where: { $0.id == preset.id }) {
                    AccountSelectionRow(
                        preset: preset,
                        input: $inputs[index]
                    )
                }
            }
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Credentials")
                    .font(.headline)
                Spacer()
                Button {
                    refreshCredentialStatuses()
                } label: {
                    Label("Check Keychain", systemImage: "key.viewfinder")
                }
            }

            if selectedInputs.isEmpty {
                Text("No accounts selected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(AccountSetupService.presets) { preset in
                    if let index = inputs.firstIndex(where: { $0.id == preset.id }), inputs[index].isSelected {
                        CredentialRow(
                            preset: preset,
                            input: inputs[index],
                            status: credentialStatuses[preset.id],
                            password: binding($passwords, preset.id),
                            totpSeed: binding($totpSeeds, preset.id)
                        )
                    }
                }
            }
        }
    }

    private var tunnelsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedInputs.isEmpty {
                Text("No accounts selected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(AccountSetupService.presets) { preset in
                    if let index = inputs.firstIndex(where: { $0.id == preset.id }), inputs[index].isSelected {
                        TunnelTargetRow(
                            preset: preset,
                            input: $inputs[index]
                        )
                    }
                }
            }
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SetupSummaryView(inputs: selectedInputs)

            Divider()

            OnboardingActionRow(
                systemImage: "network",
                title: "PAC endpoint",
                detail: appState.pacURL,
                buttonTitle: "Copy"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.pacURL, forType: .string)
            }

            OnboardingActionRow(
                systemImage: "stethoscope",
                title: "Diagnostics",
                detail: "Tunnel state, logs, and local routing status.",
                buttonTitle: "Open"
            ) {
                openWindow(id: "diagnostics")
                AppActivation.activate()
            }
        }
    }

    private func loadInputsIfNeeded() {
        guard inputs.isEmpty else { return }
        inputs = appState.defaultAccountSetupInputs()
        refreshCredentialStatuses()
    }

    private func advance() {
        if step == .accounts {
            refreshCredentialStatuses()
        }
        if let next = step.next {
            step = next
        }
    }

    private func refreshCredentialStatuses() {
        for index in inputs.indices where inputs[index].isSelected {
            let status = appState.accountSetupCredentialStatus(for: inputs[index])
            credentialStatuses[inputs[index].id] = status
            inputs[index].passwordAvailable = status.passwordState == .available
            inputs[index].totpSeedAvailable = status.totpSeedState == .available
        }
    }

    private func finish(_ finalInputs: [AccountSetupInput]) {
        do {
            _ = try appState.applyAccountSetup(inputs: finalInputs, passwords: passwords, totpSeeds: totpSeeds)
            hasCompletedOnboarding = true
            dismiss()
        } catch {
            setupMessage = error.localizedDescription
            if let setupError = error as? AccountSetupError {
                switch setupError {
                case .missingUsername:
                    step = .accounts
                case .missingPassword:
                    step = .credentials
                case .missingTunnelHost:
                    step = .tunnels
                case .unknownPreset:
                    break
                }
            }
        }
    }

    private func binding(
        _ dictionary: Binding<[AccountPresetID: String]>,
        _ id: AccountPresetID
    ) -> Binding<String> {
        Binding {
            dictionary.wrappedValue[id, default: ""]
        } set: { value in
            dictionary.wrappedValue[id] = value
        }
    }
}

private struct SetupWindowLevelConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.configure(window: view.window)
        }
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var originalLevel: NSWindow.Level?
        private var originalCollectionBehavior: NSWindow.CollectionBehavior?

        deinit {
            restore()
        }

        func configure(window: NSWindow?) {
            guard let window else { return }
            if configuredWindow !== window {
                restore()
                configuredWindow = window
                originalLevel = window.level
                originalCollectionBehavior = window.collectionBehavior
            }

            window.level = .floating
            window.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
            window.orderFrontRegardless()
        }

        private func restore() {
            guard let window = configuredWindow else { return }
            if let originalLevel {
                window.level = originalLevel
            }
            if let originalCollectionBehavior {
                window.collectionBehavior = originalCollectionBehavior
            }
            configuredWindow = nil
            originalLevel = nil
            originalCollectionBehavior = nil
        }
    }
}

private struct AccountSelectionRow: View {
    var preset: AccountSetupPreset
    @Binding var input: AccountSetupInput

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $input.isSelected) {
                    Label(preset.displayName, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                }
                Spacer()
                HelpLinksView(urls: preset.helpURLs)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Username")
                        .foregroundStyle(.secondary)
                    TextField("Username", text: $input.username)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!input.isSelected)
                }
                GridRow {
                    Text("Account host")
                        .foregroundStyle(.secondary)
                    Text(preset.credentialHost)
                        .textSelection(.enabled)
                }
                if let interactiveHost = preset.interactiveHost {
                    GridRow {
                        Text("Interactive host")
                            .foregroundStyle(.secondary)
                        Text(interactiveHost)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CredentialRow: View {
    var preset: AccountSetupPreset
    var input: AccountSetupInput
    var status: AccountSetupCredentialStatus?
    @Binding var password: String
    @Binding var totpSeed: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(preset.displayName)
                    .font(.headline)
                Spacer()
                CredentialStatusLabel(title: "Password", state: passwordState)
                CredentialStatusLabel(title: "TOTP", state: totpState)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
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
                        Text("TOTP seed")
                            .foregroundStyle(.secondary)
                        SecureField("Optional", text: $totpSeed)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("Keychain account")
                        .foregroundStyle(.secondary)
                    Text(input.username)
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

private struct TunnelTargetRow: View {
    var preset: AccountSetupPreset
    @Binding var input: AccountSetupInput

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $input.useForTunnelling) {
                Label(preset.displayName, systemImage: "server.rack")
                    .font(.headline)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Final server")
                        .foregroundStyle(.secondary)
                    EditableSuggestionField(
                        placeholder: "Server",
                        text: $input.tunnelHost,
                        suggestions: preset.suggestedTunnelHosts
                    )
                    .disabled(!input.useForTunnelling)
                }
                if let jumpHost = preset.jumpHost(username: input.username.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    GridRow {
                        Text("Bastion")
                            .foregroundStyle(.secondary)
                        Text(jumpHost)
                            .textSelection(.enabled)
                    }
                }
                if let pattern = preset.pacDomainPattern(tunnelHost: input.tunnelHost), input.useForTunnelling {
                    GridRow {
                        Text("PAC rule")
                            .foregroundStyle(.secondary)
                        Text(pattern)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

private struct SetupSummaryView: View {
    var inputs: [AccountSetupInput]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Accounts")
                .font(.headline)

            if inputs.isEmpty {
                Text("No accounts selected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(inputs) { input in
                    if let preset = AccountSetupService.preset(for: input.id) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: input.useForTunnelling ? "point.3.connected.trianglepath.dotted" : "person.crop.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName)
                                Text(summary(input: input, preset: preset))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func summary(input: AccountSetupInput, preset: AccountSetupPreset) -> String {
        guard input.useForTunnelling else {
            return "\(input.username), credentials only"
        }
        if let jumpHost = preset.jumpHost(username: input.username) {
            return "\(input.username), \(input.tunnelHost) via \(jumpHost)"
        }
        return "\(input.username), \(input.tunnelHost)"
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

private struct OnboardingActionRow: View {
    var systemImage: String
    var title: String
    var detail: String
    var buttonTitle: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .frame(width: 88)
        }
    }
}
