import AppKit
import SSHAutoTunnelCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                openWindow(id: "main")
                AppActivation.activate()
            } label: {
                Label(appState.systemPACMenuTitle, systemImage: appState.systemPACStatusSymbol)
            }
            .help(appState.systemPACStatusDetail)

            Divider()

            Button {
                appState.connectAll()
            } label: {
                Label("Connect All", systemImage: "play.fill")
            }

            Button {
                appState.disconnectAll()
            } label: {
                Label("Disconnect All", systemImage: "stop.fill")
            }

            Divider()

            Button {
                openWindow(id: "main")
                AppActivation.activate()
            } label: {
                Label("Open SSH AutoTunnel", systemImage: "macwindow")
            }

            Divider()

            if !appState.configuration.profiles.isEmpty {
                Menu {
                    Menu {
                        profileButtons(for: appState.configuration.profiles)
                    } label: {
                        Label("All Profiles", systemImage: "server.rack")
                    }
                } label: {
                    Label("Profiles", systemImage: "server.rack")
                }
            }

            if appState.configuration.profiles.contains(where: { appState.hasJumpHost($0) }) {
                Menu {
                    ForEach(appState.configuration.profiles.filter { appState.hasJumpHost($0) }) { profile in
                        let hopStatus = appState.hopStatus(for: profile)
                        Button {
                            if hopStatus?.health.isRunning == true {
                                appState.disconnectHop(profile)
                            } else {
                                appState.connectHop(profile)
                            }
                        } label: {
                            Label(profile.name.menuTruncated, systemImage: (hopStatus?.health ?? .stopped).systemImage)
                        }
                        .help(hopStatus?.health.isRunning == true
                            ? "\(hopStatus?.message ?? "Running"). Disconnecting can close terminal sessions sharing this master."
                            : hopStatus?.message ?? "Stopped")
                    }
                } label: {
                    Label("Hop Connections", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }

            if !appState.configuration.profiles.isEmpty {
                Menu {
                    ForEach(appState.configuration.profiles) { profile in
                        Button {
                            appState.connectInteractiveSSH(profile)
                        } label: {
                            Label(profile.name.menuTruncated, systemImage: "terminal")
                        }
                    }
                } label: {
                    Label("Interactive SSH", systemImage: "terminal")
                }
            }

            Divider()

            Button {
                copy(appState.pacURL)
            } label: {
                Label("Copy PAC URL", systemImage: "doc.on.doc")
            }

            Button {
                appState.toggleSystemPAC()
            } label: {
                SystemPACToggleLabel()
            }
            .help(appState.systemPACToggleHelp)

            Divider()

            Button {
                openWindow(id: "settings")
                AppActivation.activate()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                openWindow(id: "diagnostics")
                AppActivation.activate()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Menu {
                Button {
                    openConnectionTemplateSetup()
                } label: {
                    Label("From Template...", systemImage: "list.bullet.rectangle")
                }

                Button {
                    createBlankProfile()
                } label: {
                    Label("Blank Profile", systemImage: "plus")
                }
            } label: {
                Label("New Connection", systemImage: "plus.circle")
            }

            Divider()

            Text(appState.lastProxyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private func profileButtons(for profiles: [TunnelProfile]) -> some View {
        ForEach(profiles) { profile in
            let status = appState.status(for: profile)
            Button {
                if status.health.isRunning {
                    appState.disconnect(profile)
                } else {
                    appState.connect(profile)
                }
            } label: {
                Label(profile.name.menuTruncated, systemImage: status.health.systemImage)
            }
            .help(status.message)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openConnectionTemplateSetup() {
        openWindow(id: "connection-template-setup")
        AppActivation.activate()
    }

    private func createBlankProfile() {
        let profileID = appState.addGenericProfile()
        DashboardNavigationRequest.shared.selectProfile(profileID)
        openWindow(id: "main")
        AppActivation.activate()
    }
}
