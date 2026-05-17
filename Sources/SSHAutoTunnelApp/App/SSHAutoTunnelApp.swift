import AppKit
import SwiftUI

@main
struct SSHAutoTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // System proxy restoration is also available explicitly from the menu.
    }
}
