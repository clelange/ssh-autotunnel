import AppIntents
import Foundation
import SSHAutoTunnelCore

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect SSH Tunnel"
    static var description = IntentDescription("Connect an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "CERN lxplus"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .connect, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect SSH Tunnel"
    static var description = IntentDescription("Disconnect an SSH AutoTunnel profile.")

    @Parameter(title: "Profile Name")
    var profileName: String

    init() {
        profileName = "CERN lxplus"
    }

    init(profileName: String) {
        self.profileName = profileName
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .disconnect, profileName: profileName))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct TunnelStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel Status"
    static var description = IntentDescription("Get the current SSH AutoTunnel status.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .status))
        let summary = response.status?.profiles.map { "\($0.name): \($0.health.rawValue)" }.joined(separator: ", ") ?? response.message
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

struct PACURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Get SSH AutoTunnel PAC URL"
    static var description = IntentDescription("Get the local PAC URL for SSH AutoTunnel.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await api().send(ControlRequest(action: .pacURL))
        return .result(dialog: IntentDialog(stringLiteral: response.message))
    }
}

struct SSHAutoTunnelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTunnelIntent(profileName: "CERN lxplus"),
            phrases: ["Connect \(.applicationName) tunnel"],
            shortTitle: "Connect Tunnel",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(profileName: "CERN lxplus"),
            phrases: ["Disconnect \(.applicationName) tunnel"],
            shortTitle: "Disconnect Tunnel",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: TunnelStatusIntent(),
            phrases: ["Check \(.applicationName) status"],
            shortTitle: "Tunnel Status",
            systemImageName: "stethoscope"
        )
        AppShortcut(
            intent: PACURLIntent(),
            phrases: ["Get \(.applicationName) PAC URL"],
            shortTitle: "PAC URL",
            systemImageName: "doc.on.doc"
        )
    }
}

private func api() throws -> ControlAPIClient {
    let configuration = try ConfigurationStore().load()
    return ControlAPIClient(configuration: configuration)
}
