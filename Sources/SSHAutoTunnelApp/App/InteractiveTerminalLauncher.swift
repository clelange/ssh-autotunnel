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
    func launch(command: SSHCommand, preference: InteractiveTerminalPreference) throws {
        switch preference.app {
        case .terminal:
            try launchTerminal(command)
        case .iTerm2:
            try launchITerm2(command)
        case .ghostty:
            try launchGhostty(command)
        case .custom:
            try launchCustom(command, applicationPath: preference.customApplicationPath)
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

    private func launchTerminal(_ command: SSHCommand) throws {
        guard let bundleIdentifier = InteractiveTerminalApp.terminal.bundleIdentifier,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw InteractiveTerminalLaunchError.terminalUnavailable(InteractiveTerminalApp.terminal.displayName)
        }
        let script = """
        tell application id "\(bundleIdentifier)"
            activate
            do script \(appleScriptString(command.shellCommand))
        end tell
        """
        try runAppleScript(script)
    }

    private func launchITerm2(_ command: SSHCommand) throws {
        guard let bundleIdentifier = InteractiveTerminalApp.iTerm2.bundleIdentifier,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw InteractiveTerminalLaunchError.terminalUnavailable(InteractiveTerminalApp.iTerm2.displayName)
        }
        let script = """
        tell application id "\(bundleIdentifier)"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text \(appleScriptString(command.shellCommand))
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    private func launchGhostty(_ command: SSHCommand) throws {
        guard let bundleIdentifier = InteractiveTerminalApp.ghostty.bundleIdentifier,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
            throw InteractiveTerminalLaunchError.terminalUnavailable(InteractiveTerminalApp.ghostty.displayName)
        }
        try runOpen(arguments: ["-b", bundleIdentifier, "--args", "-e", command.executable] + command.arguments)
    }

    private func launchCustom(_ command: SSHCommand, applicationPath: String) throws {
        let trimmedPath = applicationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, FileManager.default.fileExists(atPath: trimmedPath) else {
            throw InteractiveTerminalLaunchError.customApplicationMissing
        }
        try runOpen(arguments: [trimmedPath, "--args", "-e", command.executable] + command.arguments)
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

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
