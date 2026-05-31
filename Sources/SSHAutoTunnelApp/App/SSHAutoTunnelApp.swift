import AppKit
import OSLog
import SSHAutoTunnelCore
import SwiftUI

@main
struct SSHAutoTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("SSH AutoTunnel", id: "main") {
            DashboardView()
                .environmentObject(appState)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultLaunchBehavior(.presented)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
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
        }

        Window("SSH AutoTunnel Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 760, minHeight: 500)
        }

        Window("SSH AutoTunnel Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(appState)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppPaths.appIdentifier, category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppActivation.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        do {
            try SystemProxyManager().restoreIfNeeded()
            logger.info("Checked system PAC restore state during app termination")
        } catch {
            logger.error("System PAC restore failed during app termination: \(error.localizedDescription, privacy: .public)")
        }
    }
}
