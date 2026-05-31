import AppKit
import Foundation
import SSHAutoTunnelCore

enum InteractiveTerminalLaunchError: LocalizedError {
    case terminalUnavailable(String)
    case customApplicationMissing
    case appleScriptFailed(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .terminalUnavailable(let name):
            "\(name) is not installed or cannot be found."
        case .customApplicationMissing:
            "Choose a custom terminal application in Settings first."
        case .appleScriptFailed(let message):
            "Terminal automation failed: \(message)"
        case .openFailed(let message):
            "Could not launch terminal: \(message)"
        }
    }
}

struct InteractiveTerminalLauncher {
    func launch(
        command: SSHCommand,
        preference: InteractiveTerminalPreference,
        activeSessionMarkerURL: URL? = nil
    ) throws {
        switch preference.app {
        case .terminal:
            try launchTerminal(command, activeSessionMarkerURL: activeSessionMarkerURL)
        case .iTerm2:
            try launchITerm2(command, activeSessionMarkerURL: activeSessionMarkerURL)
        case .ghostty:
            try launchGhostty(command, activeSessionMarkerURL: activeSessionMarkerURL)
        case .custom:
            try launchCustom(
                command,
                applicationPath: preference.customApplicationPath,
                activeSessionMarkerURL: activeSessionMarkerURL
            )
        }
    }

    func isAvailable(_ preference: InteractiveTerminalPreference) -> Bool {
        switch preference.app {
        case .terminal, .iTerm2, .ghostty:
            guard let bundleIdentifier = preference.app.bundleIdentifier else { return false }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        case .custom:
            return FileManager.default.fileExists(atPath: preference.customApplicationPath)
        }
    }

    private func launchTerminal(_ command: SSHCommand, activeSessionMarkerURL: URL?) throws {
        guard let bundleIdentifier = InteractiveTerminalApp.terminal.bundleIdentifier,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw InteractiveTerminalLaunchError.terminalUnavailable(InteractiveTerminalApp.terminal.displayName)
        }
        let scriptURL = try writeCommandScript(for: command, activeSessionMarkerURL: activeSessionMarkerURL)
        do {
            try runOpen(arguments: ["-b", bundleIdentifier, scriptURL.path])
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw error
        }
    }

    private func launchITerm2(_ command: SSHCommand, activeSessionMarkerURL: URL?) throws {
        guard let bundleIdentifier = InteractiveTerminalApp.iTerm2.bundleIdentifier,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw InteractiveTerminalLaunchError.terminalUnavailable(InteractiveTerminalApp.iTerm2.displayName)
        }
        let script = """
        tell application id "\(bundleIdentifier)"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text \(appleScriptString(shellSessionCommand(for: command, activeSessionMarkerURL: activeSessionMarkerURL)))
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    private func launchGhostty(_ command: SSHCommand, activeSessionMarkerURL: URL?) throws {
        guard let bundleIdentifier = InteractiveTerminalApp.ghostty.bundleIdentifier,
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw InteractiveTerminalLaunchError.terminalUnavailable(InteractiveTerminalApp.ghostty.displayName)
        }
        try runOpen(arguments: ["-n", applicationURL.path, "--args"] + terminalEmulatorArguments(for: command, activeSessionMarkerURL: activeSessionMarkerURL))
    }

    private func launchCustom(
        _ command: SSHCommand,
        applicationPath: String,
        activeSessionMarkerURL: URL?
    ) throws {
        let trimmedPath = applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, FileManager.default.fileExists(atPath: trimmedPath) else {
            throw InteractiveTerminalLaunchError.customApplicationMissing
        }
        try runOpen(arguments: ["-n", trimmedPath, "--args"] + terminalEmulatorArguments(for: command, activeSessionMarkerURL: activeSessionMarkerURL))
    }

    private func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw InteractiveTerminalLaunchError.appleScriptFailed("Could not create AppleScript.")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? errorInfo.description
            throw InteractiveTerminalLaunchError.appleScriptFailed(message)
        }
    }

    private func runOpen(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InteractiveTerminalLaunchError.openFailed(message?.isEmpty == false ? message! : "open exited with status \(process.terminationStatus)")
        }
    }

    private func terminalEmulatorArguments(for command: SSHCommand, activeSessionMarkerURL: URL?) -> [String] {
        [
            "-e",
            "/bin/zsh",
            "-lc",
            shellSessionCommand(for: command, activeSessionMarkerURL: activeSessionMarkerURL)
        ]
    }

    private func writeCommandScript(for command: SSHCommand, activeSessionMarkerURL: URL?) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHAutoTunnel-\(UUID().uuidString).command")
        let source = "#!/bin/zsh\n\(shellSessionCommand(for: command, cleanupPath: scriptURL.path, activeSessionMarkerURL: activeSessionMarkerURL))\n"
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func shellSessionCommand(
        for command: SSHCommand,
        cleanupPath: String? = nil,
        activeSessionMarkerURL: URL? = nil
    ) -> String {
        let markerPath = activeSessionMarkerURL?.path
        var lines: [String] = []
        if let markerPath {
            let quotedMarkerPath = SSHCommand.shellQuoted(markerPath)
            lines.append("trap 'rm -f \(quotedMarkerPath)' EXIT INT TERM HUP")
        }
        lines += [
            command.shellCommand,
            "ssh_autotunnel_status=$?",
        ]
        if let markerPath {
            lines.append("rm -f \(SSHCommand.shellQuoted(markerPath))")
        }
        lines += [
            "printf '\\nSSH session ended with exit status %d. Press Ctrl-D to close this window.\\n' \"$ssh_autotunnel_status\""
        ]
        if let cleanupPath {
            lines.append("rm -f \(SSHCommand.shellQuoted(cleanupPath))")
        }
        lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        return lines.joined(separator: "\n")
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
