import Foundation

public struct CLIInvocation: Equatable, Sendable {
    public var command: String
    public var profileName: String?
    public var outputJSON: Bool

    public init(command: String, profileName: String? = nil, outputJSON: Bool = false) {
        self.command = command
        self.profileName = profileName
        self.outputJSON = outputJSON
    }
}

public enum CLIArguments {
    public static func parse(_ arguments: [String]) -> CLIInvocation? {
        var outputJSON = false
        var positional: [String] = []

        for argument in arguments {
            switch argument {
            case "--json", "-j":
                outputJSON = true
            default:
                positional.append(argument)
            }
        }

        guard let command = positional.first else { return nil }
        let profileName = positional.dropFirst().isEmpty ? nil : positional.dropFirst().joined(separator: " ")
        return CLIInvocation(command: command, profileName: profileName, outputJSON: outputJSON)
    }
}
