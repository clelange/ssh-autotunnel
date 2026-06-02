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
            Label("SSH AutoTunnel", systemImage: "point.3.connected.trianglepath.dotted")
                .overlay {
                    OnboardingPresenter()
                }
        }
        .menuBarExtraStyle(.menu)

        Window("SSH AutoTunnel Setup", id: "onboarding") {
            OnboardingView()
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
                .frame(minWidth: 760, minHeight: 500)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppPaths.appIdentifier, category: "lifecycle")
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppActivation.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let activeSessions = appState?.activeHopInteractiveSessions() ?? []
        guard !activeSessions.isEmpty else {
            appState?.prepareForTermination()
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit SSH AutoTunnel?"
        alert.informativeText = quitWarningText(for: activeSessions)
        alert.addButton(withTitle: "Quit and Disconnect")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            appState?.prepareForTermination()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.prepareForTermination()
        do {
            try SystemProxyManager().restoreIfNeeded()
            logger.info("Checked system PAC restore state during app termination")
        } catch {
            logger.error("System PAC restore failed during app termination: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func quitWarningText(for sessions: [ActiveInteractiveSSHSession]) -> String {
        let shownSessions = sessions.prefix(5).map { session in
            "\(session.profileName) via \(session.jumpHost)"
        }
        var text = "There are active interactive SSH sessions using hop connections. Quitting will stop SSH AutoTunnel tunnels and hop connections, which may disconnect those sessions.\n\n"
        text += shownSessions.joined(separator: "\n")
        if sessions.count > shownSessions.count {
            text += "\n...and \(sessions.count - shownSessions.count) more"
        }
        text += "\n\nCancel to keep SSH AutoTunnel running."
        return text
    }
}
