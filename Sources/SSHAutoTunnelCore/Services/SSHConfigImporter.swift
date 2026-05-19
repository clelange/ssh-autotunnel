import Foundation

public struct SSHConfigImportResult: Equatable, Sendable {
    public var createdProfiles: Int
    public var updatedProfiles: Int
    public var skippedHosts: Int

    public init(createdProfiles: Int = 0, updatedProfiles: Int = 0, skippedHosts: Int = 0) {
        self.createdProfiles = createdProfiles
        self.updatedProfiles = updatedProfiles
        self.skippedHosts = skippedHosts
    }
}

public enum SSHConfigImporter {
    public static func apply(
        to configuration: AppConfiguration,
        configText: String,
        startingPort: Int = 1083
    ) -> (AppConfiguration, SSHConfigImportResult) {
        var configuration = configuration
        var result = SSHConfigImportResult()

        for entry in SSHConfigParser.parse(configText) {
            let literalAliases = entry.hostPatterns.filter(Self.isLiteralHostPattern)
            if literalAliases.isEmpty {
                result.skippedHosts += entry.hostPatterns.count
                continue
            }

            for alias in literalAliases {
                upsertProfile(alias: alias, entry: entry, startingPort: startingPort, configuration: &configuration, result: &result)
            }

            result.skippedHosts += entry.hostPatterns.count - literalAliases.count
        }

        return (configuration, result)
    }

    private static func upsertProfile(
        alias: String,
        entry: SSHConfigEntry,
        startingPort: Int,
        configuration: inout AppConfiguration,
        result: inout SSHConfigImportResult
    ) {
        let host = entry.hostName.map { expandHostTokens($0, alias: alias, user: entry.user) } ?? alias
        let sshPort = entry.port ?? 22
        let extraOptions = entry.extraSSHOptions

        if let index = configuration.profiles.firstIndex(where: { $0.name == alias }) {
            configuration.profiles[index].host = host
            configuration.profiles[index].user = entry.user
            configuration.profiles[index].sshPort = sshPort
            configuration.profiles[index].jumpHost = entry.proxyJump
            configuration.profiles[index].extraSSHOptions = extraOptions
            if configuration.profiles[index].healthProbe == nil {
                configuration.profiles[index].healthProbe = HealthProbe(host: host, port: sshPort)
            }
            result.updatedProfiles += 1
            return
        }

        let profile = TunnelProfile(
            name: alias,
            host: host,
            user: entry.user,
            sshPort: sshPort,
            localSocksPort: nextFreePort(startingAt: startingPort, profiles: configuration.profiles),
            jumpHost: entry.proxyJump,
            authMode: .none,
            healthProbe: HealthProbe(host: host, port: sshPort),
            extraSSHOptions: extraOptions
        )
        configuration.profiles.append(profile)
        result.createdProfiles += 1
    }

    private static func isLiteralHostPattern(_ pattern: String) -> Bool {
        !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
    }

    private static func expandHostTokens(_ value: String, alias: String, user: String?) -> String {
        value
            .replacingOccurrences(of: "%%", with: "\u{0}")
            .replacingOccurrences(of: "%h", with: alias)
            .replacingOccurrences(of: "%n", with: alias)
            .replacingOccurrences(of: "%r", with: user ?? "")
            .replacingOccurrences(of: "\u{0}", with: "%")
    }

    private static func nextFreePort(startingAt startingPort: Int, profiles: [TunnelProfile]) -> Int {
        let used = Set(profiles.map(\.localSocksPort))
        var port = startingPort
        while used.contains(port) {
            port += 1
        }
        return port
    }
}

public struct SSHConfigEntry: Equatable, Sendable {
    public var hostPatterns: [String]
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var proxyJump: String?
    public var extraSSHOptions: [String]

    public init(
        hostPatterns: [String],
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        proxyJump: String? = nil,
        extraSSHOptions: [String] = []
    ) {
        self.hostPatterns = hostPatterns
        self.hostName = hostName
        self.user = user
        self.port = port
        self.proxyJump = proxyJump
        self.extraSSHOptions = extraSSHOptions
    }
}

public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: MutableSSHConfigEntry?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let directive = parseDirective(line) else { continue }

            if directive.keyword == "host" {
                if let entry = current?.entry {
                    entries.append(entry)
                }
                current = MutableSSHConfigEntry(hostPatterns: directive.values)
                continue
            }

            guard current != nil else { continue }
            apply(directive: directive, to: &current!)
        }

        if let entry = current?.entry {
            entries.append(entry)
        }
        return entries
    }

    private static func apply(directive: SSHConfigDirective, to entry: inout MutableSSHConfigEntry) {
        guard let firstValue = directive.values.first else { return }

        switch directive.keyword {
        case "hostname":
            entry.hostName = firstValue
        case "user":
            entry.user = firstValue
        case "port":
            entry.port = Int(firstValue)
        case "proxyjump":
            entry.proxyJump = firstValue == "none" ? nil : firstValue
        case "identityfile":
            entry.extraSSHOptions += ["-i", firstValue]
        case "certificatefile", "identitiesonly", "forwardagent", "gssapiauthentication", "gssapidelegatecredentials", "kbdinteractiveauthentication", "preferredauthentications":
            entry.extraSSHOptions += ["-o", "\(directive.originalKeyword)=\(directive.values.joined(separator: " "))"]
        case "proxycommand":
            entry.extraSSHOptions += ["-o", "\(directive.originalKeyword)=\(directive.values.joined(separator: " "))"]
        default:
            break
        }
    }

    private static func parseDirective(_ line: String) -> SSHConfigDirective? {
        let parts = tokenize(line)
        guard let keyword = parts.first else { return nil }

        if let equalIndex = keyword.firstIndex(of: "=") {
            let rawKeyword = String(keyword[..<equalIndex])
            let firstValue = String(keyword[keyword.index(after: equalIndex)...])
            return SSHConfigDirective(originalKeyword: rawKeyword, values: ([firstValue] + parts.dropFirst()).filter { !$0.isEmpty })
        }

        return SSHConfigDirective(originalKeyword: keyword, values: Array(parts.dropFirst()))
    }

    private static func stripComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }

            if character == "\\" {
                result.append(character)
                escaped = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                result.append(character)
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                result.append(character)
                continue
            }

            if character == "#" {
                break
            }

            result.append(character)
        }

        return result
    }

    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }

            if character == "\\" {
                escaped = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}

private struct MutableSSHConfigEntry {
    var hostPatterns: [String]
    var hostName: String?
    var user: String?
    var port: Int?
    var proxyJump: String?
    var extraSSHOptions: [String] = []

    var entry: SSHConfigEntry {
        SSHConfigEntry(
            hostPatterns: hostPatterns,
            hostName: hostName,
            user: user,
            port: port,
            proxyJump: proxyJump,
            extraSSHOptions: extraSSHOptions
        )
    }
}

private struct SSHConfigDirective {
    var originalKeyword: String
    var values: [String]

    var keyword: String {
        originalKeyword.lowercased()
    }
}
