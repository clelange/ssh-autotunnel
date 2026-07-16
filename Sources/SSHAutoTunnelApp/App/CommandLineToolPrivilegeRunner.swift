import AppKit
import Foundation
import SSHAutoTunnelCore

enum CommandLineToolPrivilegeResult: Equatable {
    case completed
    case cancelled
}

enum CommandLineToolPrivilegeError: LocalizedError {
    case couldNotCreateScript
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateScript:
            "Could not create the administrator authorization script"
        case .operationFailed(let message):
            message
        }
    }
}

struct CommandLineToolPrivilegeRunner {
    func perform(
        _ operation: CommandLineToolPrivilegedOperation,
        layout: CommandLineToolInstallationLayout
    ) throws -> CommandLineToolPrivilegeResult {
        let source = CommandLineToolPrivilegedScript.source(operation: operation, layout: layout)
        guard let script = NSAppleScript(source: source) else {
            throw CommandLineToolPrivilegeError.couldNotCreateScript
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else {
            return .completed
        }

        let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if number == -128 {
            return .cancelled
        }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "The administrator-authorized command-line tool operation failed"
        throw CommandLineToolPrivilegeError.operationFailed(message)
    }
}
