import AppKit
import OSLog
import SSHAutoTunnelCore
import SwiftUI

@main
struct SSHAutoTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("SSH AutoTunnel", id: "main") {
            DashboardView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultLaunchBehavior(.presented)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        } label: {
            MenuBarExtraStatusLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Window("New Connection", id: "connection-template-setup") {
            ConnectionTemplateSetupView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        }

        Window("SSH AutoTunnel Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
                .frame(minWidth: 640, minHeight: 460)
        }

        Window("SSH AutoTunnel Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppPaths.appIdentifier, category: "lifecycle")
    private let appIconAppearanceController = AppIconAppearanceController()
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        appIconAppearanceController.start()
        AppActivation.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let activeConnections = appState?.activeQuitConnectionWarnings() ?? []
        guard !activeConnections.isEmpty else {
            appState?.prepareForTermination()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit SSH AutoTunnel?"
        alert.informativeText = quitWarningText(for: activeConnections)
        alert.addButton(withTitle: "Quit and Stop App-Owned Connections")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            appState?.prepareForTermination()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        appIconAppearanceController.stop()
        appState?.prepareForTermination()
        do {
            try SystemProxyManager().restoreIfNeeded()
            logger.info("Checked system PAC restore state during app termination")
        } catch {
            logger.error("System PAC restore failed during app termination: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func quitWarningText(for connections: [QuitConnectionWarning]) -> String {
        let shownConnections = connections.prefix(5).map(\.displayLine)
        var text = "SSH AutoTunnel detected active SSH connections or sessions.\n\n"
        text += shownConnections.joined(separator: "\n")
        if connections.count > shownConnections.count {
            text += "\n...and \(connections.count - shownConnections.count) more"
        }
        if connections.contains(where: { !$0.isAppOwnedConnection }) {
            text += "\n\nQuitting will stop app-owned tunnels and hop connections. Untracked listeners or terminal sessions may remain and may need manual cleanup."
        } else {
            text += "\n\nQuitting will stop app-owned tunnels and hop connections."
        }
        text += " Terminal sessions configured to share an app-owned hop master may also be disconnected."
        text += "\n\nCancel to keep SSH AutoTunnel running."
        return text
    }
}
