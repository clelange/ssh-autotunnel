import Foundation

public struct CLIInvocation: Equatable, Sendable {
    public var command: String
    public var profileName: String?
    public var outputJSON: Bool
    public var deleteKeychainItems: Bool

    public init(
        command: String,
        profileName: String? = nil,
        outputJSON: Bool = false,
        deleteKeychainItems: Bool = false
    ) {
        self.command = command
        self.profileName = profileName
        self.outputJSON = outputJSON
        self.deleteKeychainItems = deleteKeychainItems
    }
}

public enum CLIArguments {
    public static func parse(_ arguments: [String]) -> CLIInvocation? {
        var outputJSON = false
        var deleteKeychainItems = false
        var positional: [String] = []

        for argument in arguments {
            switch argument {
            case "--json", "-j":
                outputJSON = true
            case "--delete-keychain", "--delete-keychain-items":
                deleteKeychainItems = true
            default:
                positional.append(argument)
            }
        }

        guard let command = positional.first else { return nil }
        let profileName = positional.dropFirst().isEmpty ? nil : positional.dropFirst().joined(separator: " ")
        return CLIInvocation(
            command: command,
            profileName: profileName,
            outputJSON: outputJSON,
            deleteKeychainItems: deleteKeychainItems
        )
    }
}
