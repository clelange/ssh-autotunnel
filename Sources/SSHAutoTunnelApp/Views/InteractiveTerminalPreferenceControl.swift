import AppKit
import SSHAutoTunnelCore
import SwiftUI
import UniformTypeIdentifiers

struct InteractiveTerminalPreferenceControl: View {
    enum Style {
        case dashboard
        case settings
    }

    @EnvironmentObject private var appState: AppState
    var style: Style

    var body: some View {
        Group {
            switch style {
            case .dashboard:
                dashboardControl
            case .settings:
                settingsControl
            }
        }
        .onAppear {
            appState.refreshInteractiveTerminalDiscovery()
        }
    }

    private var dashboardControl: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Interactive SSH Terminal")
                    .font(.headline)
                Text(appState.interactiveTerminalAvailabilityMessage())
                    .font(.caption)
                    .foregroundStyle(availabilityColor)
            }

            Spacer(minLength: 12)

            Picker("Terminal app", selection: terminalAppBinding) {
                pickerOptions
            }
            .labelsHidden()
            .frame(width: 180)
            .help("Choose the terminal app used for interactive SSH sessions")

            if appState.configuration.interactiveTerminal.app == .custom {
                Button {
                    chooseTerminalApplication()
                } label: {
                    Label("Choose", systemImage: "folder")
                }
                .help("Choose a custom terminal app for interactive SSH")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var settingsControl: some View {
        Picker("Terminal app", selection: terminalAppBinding) {
            pickerOptions
        }

        if appState.configuration.interactiveTerminal.app == .custom {
            HStack {
                TextField("Application", text: customApplicationPathBinding)
                Button("Choose...") {
                    chooseTerminalApplication()
                }
                .help("Choose a custom terminal app for interactive SSH")
            }
            Text("Custom terminal apps must accept command launches with `-e /bin/zsh -lc ...`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Text(appState.interactiveTerminalAvailabilityMessage())
            .font(.caption)
            .foregroundStyle(availabilityColor)
    }

    @ViewBuilder
    private var pickerOptions: some View {
        ForEach(appState.interactiveTerminalOptions()) { option in
            Label {
                Text(title(for: option))
            } icon: {
                TerminalApplicationIcon(
                    app: option.app,
                    applicationPath: applicationPath(for: option),
                    size: 13
                )
            }
            .tag(option.app)
        }
    }

    private var terminalAppBinding: Binding<InteractiveTerminalApp> {
        Binding(
            get: { appState.configuration.interactiveTerminal.app },
            set: { app in
                guard appState.configuration.interactiveTerminal.app != app else { return }
                appState.configuration.interactiveTerminal.app = app
                appState.scheduleConfigurationSave()
            }
        )
    }

    private var customApplicationPathBinding: Binding<String> {
        Binding(
            get: { appState.configuration.interactiveTerminal.customApplicationPath },
            set: { path in
                appState.configuration.interactiveTerminal.customApplicationPath = path
                appState.scheduleConfigurationSave()
            }
        )
    }

    private var availabilityColor: Color {
        appState.isInteractiveTerminalAvailable(appState.configuration.interactiveTerminal) ? .secondary : .red
    }

    private func title(for option: InteractiveTerminalOption) -> String {
        guard option.app != .custom, !option.isInstalled else {
            return option.app.displayName
        }
        return "\(option.app.displayName) (not installed)"
    }

    private func applicationPath(for option: InteractiveTerminalOption) -> String? {
        if option.app == .custom {
            return appState.configuration.interactiveTerminal.customApplicationPath
        }
        return option.applicationPath
    }

    private func chooseTerminalApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.configuration.interactiveTerminal.app = .custom
        appState.configuration.interactiveTerminal.customApplicationPath = url.path
        appState.saveConfiguration()
    }
}

private struct TerminalApplicationIcon: View {
    var app: InteractiveTerminalApp
    var applicationPath: String?
    var size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var icon: NSImage? {
        guard let path = applicationPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return sizedIcon(NSWorkspace.shared.icon(forFile: path))
    }

    private var fallbackSystemImage: String {
        app == .custom ? "app.dashed" : "terminal"
    }

    private func sizedIcon(_ image: NSImage) -> NSImage {
        let icon = image.copy() as? NSImage ?? image
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
