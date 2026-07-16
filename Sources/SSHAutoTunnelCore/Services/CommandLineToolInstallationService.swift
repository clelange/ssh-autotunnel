import Foundation

public enum CommandLineToolInstallationStatus: Equatable, Sendable {
    case unavailable(reason: String)
    case notInstalled
    case installed
    case conflict(reason: String)

    public var displayName: String {
        switch self {
        case .unavailable:
            "Unavailable"
        case .notInstalled:
            "Not installed"
        case .installed:
            "Installed"
        case .conflict:
            "Conflict"
        }
    }
}

public enum CommandLineToolInstallationError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case destinationConflict(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            reason
        case .destinationConflict(let path):
            "An existing item at \(path) is not managed by SSH AutoTunnel"
        }
    }
}

public struct CommandLineToolInstallationLayout: Equatable, Sendable {
    public static let requiredAppBundleURL = URL(fileURLWithPath: "/Applications/SSHAutoTunnel.app", isDirectory: true)
    public static let defaultDestinationURL = URL(fileURLWithPath: "/usr/local/bin/ssh-autotunnelctl")

    public var appBundleURL: URL
    public var requiredAppBundleURL: URL
    public var destinationURL: URL

    public init(
        appBundleURL: URL,
        requiredAppBundleURL: URL = Self.requiredAppBundleURL,
        destinationURL: URL = Self.defaultDestinationURL
    ) {
        self.appBundleURL = appBundleURL
        self.requiredAppBundleURL = requiredAppBundleURL
        self.destinationURL = destinationURL
    }

    public var helperURL: URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ssh-autotunnelctl")
    }

    public var isAppInstalledAtRequiredLocation: Bool {
        appBundleURL.standardizedFileURL == requiredAppBundleURL.standardizedFileURL
    }
}

public struct CommandLineToolInstallationService {
    public let layout: CommandLineToolInstallationLayout
    private let fileManager: FileManager

    public init(
        layout: CommandLineToolInstallationLayout,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
    }

    public func status() -> CommandLineToolInstallationStatus {
        guard layout.isAppInstalledAtRequiredLocation else {
            return .unavailable(
                reason: "Move SSHAutoTunnel.app to /Applications before installing the command-line tool."
            )
        }
        guard fileManager.isExecutableFile(atPath: layout.helperURL.path) else {
            return .unavailable(
                reason: "The embedded ssh-autotunnelctl helper is missing or is not executable."
            )
        }

        if let target = try? fileManager.destinationOfSymbolicLink(atPath: layout.destinationURL.path) {
            if target == layout.helperURL.path {
                return .installed
            }
            return .conflict(
                reason: "\(layout.destinationURL.path) is a different symbolic link and will not be replaced."
            )
        }
        if fileManager.fileExists(atPath: layout.destinationURL.path) {
            return .conflict(
                reason: "\(layout.destinationURL.path) already exists and will not be replaced."
            )
        }
        return .notInstalled
    }

    @discardableResult
    public func install() throws -> Bool {
        switch status() {
        case .installed:
            return false
        case .notInstalled:
            try fileManager.createDirectory(
                at: layout.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(at: layout.destinationURL, withDestinationURL: layout.helperURL)
            return true
        case .unavailable(let reason):
            throw CommandLineToolInstallationError.unavailable(reason)
        case .conflict:
            throw CommandLineToolInstallationError.destinationConflict(layout.destinationURL.path)
        }
    }

    @discardableResult
    public func uninstall() throws -> Bool {
        switch status() {
        case .installed:
            guard (try? fileManager.destinationOfSymbolicLink(atPath: layout.destinationURL.path)) == layout.helperURL.path else {
                throw CommandLineToolInstallationError.destinationConflict(layout.destinationURL.path)
            }
            try fileManager.removeItem(at: layout.destinationURL)
            return true
        case .notInstalled:
            return false
        case .unavailable(let reason):
            throw CommandLineToolInstallationError.unavailable(reason)
        case .conflict:
            throw CommandLineToolInstallationError.destinationConflict(layout.destinationURL.path)
        }
    }

    public static func requiresAdministratorPrivileges(for error: Error) -> Bool {
        containsPermissionError(error as NSError)
    }

    private static func containsPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(EACCES) || error.code == Int(EPERM) {
            return true
        }
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.Code.fileWriteNoPermission.rawValue ||
           error.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return containsPermissionError(underlying)
        }
        return false
    }
}

public enum CommandLineToolPrivilegedOperation: String, Equatable, Sendable {
    case install
    case uninstall
}

public enum CommandLineToolPrivilegedScript {
    public static func source(
        operation: CommandLineToolPrivilegedOperation,
        layout: CommandLineToolInstallationLayout
    ) -> String {
        let helper = appleScriptLiteral(layout.helperURL.path)
        let destination = appleScriptLiteral(layout.destinationURL.path)
        let destinationDirectory = appleScriptLiteral(layout.destinationURL.deletingLastPathComponent().path)
        let localDirectory = appleScriptLiteral(layout.destinationURL.deletingLastPathComponent().deletingLastPathComponent().path)
        let shellBody = operation == .install ? installShellBody : uninstallShellBody

        return """
        set helperPath to \(helper)
        set destinationPath to \(destination)
        set destinationDirectoryPath to \(destinationDirectory)
        set localDirectoryPath to \(localDirectory)
        set helperArg to quoted form of helperPath
        set destinationArg to quoted form of destinationPath
        set destinationDirectoryArg to quoted form of destinationDirectoryPath
        set localDirectoryArg to quoted form of localDirectoryPath
        set shellCommand to \(appleScriptLiteral(shellBody))
        set shellCommand to shellCommand & " " & helperArg & " " & destinationArg & " " & destinationDirectoryArg & " " & localDirectoryArg
        do shell script shellCommand with administrator privileges
        """
    }

    private static let installShellBody = """
    /bin/sh -c 'helper="$1"; destination="$2"; destination_directory="$3"; local_directory="$4"; if [ ! -x "$helper" ]; then /bin/echo "Embedded command-line tool is unavailable" >&2; exit 20; fi; if [ -L "$local_directory" ] || { [ -e "$local_directory" ] && [ ! -d "$local_directory" ]; }; then /bin/echo "Unsafe /usr/local path" >&2; exit 21; fi; if [ -L "$destination_directory" ] || { [ -e "$destination_directory" ] && [ ! -d "$destination_directory" ]; }; then /bin/echo "Unsafe command-line tool directory" >&2; exit 22; fi; /bin/mkdir -p "$destination_directory"; if [ -L "$destination" ]; then if [ "$(/usr/bin/readlink "$destination")" = "$helper" ]; then exit 0; fi; /bin/echo "Command-line tool destination is a different symbolic link" >&2; exit 23; fi; if [ -e "$destination" ]; then /bin/echo "Command-line tool destination already exists" >&2; exit 24; fi; /bin/ln -s "$helper" "$destination"' --
    """

    private static let uninstallShellBody = """
    /bin/sh -c 'helper="$1"; destination="$2"; if [ -L "$destination" ]; then if [ "$(/usr/bin/readlink "$destination")" = "$helper" ]; then /bin/rm "$destination"; exit 0; fi; /bin/echo "Command-line tool destination is a different symbolic link" >&2; exit 23; fi; if [ -e "$destination" ]; then /bin/echo "Command-line tool destination is not a managed symbolic link" >&2; exit 24; fi; exit 0' --
    """

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
