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
        let curatedOptions = entry.curatedSSHOptions
        let jumpHost = curatedOptions.proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? nil : entry.proxyJump

        if let index = configuration.profiles.firstIndex(where: { $0.name == alias }) {
            configuration.profiles[index].host = host
            configuration.profiles[index].user = entry.user
            configuration.profiles[index].sshPort = sshPort
            configuration.profiles[index].jumpHost = jumpHost
            configuration.profiles[index].curatedSSHOptions = curatedOptions
            configuration.profiles[index].localPortForwardings = entry.localPortForwardings
            configuration.profiles[index].extraSSHOptions = extraOptions
            if let sshLogLevel = entry.sshLogLevel {
                configuration.profiles[index].sshLogLevel = sshLogLevel
            }
            if let dynamicForwardPort = entry.dynamicForwardPort {
                configuration.profiles[index].localSocksPort = dynamicForwardPort
            }
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
            localSocksPort: entry.dynamicForwardPort ?? nextFreePort(startingAt: startingPort, profiles: configuration.profiles),
            jumpHost: jumpHost,
            authMode: .none,
            healthProbe: HealthProbe(host: host, port: sshPort),
            sshLogLevel: entry.sshLogLevel ?? .info,
            localPortForwardings: entry.localPortForwardings,
            curatedSSHOptions: curatedOptions,
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
    public var dynamicForwardPort: Int?
    public var localPortForwardings: [LocalPortForward]
    public var curatedSSHOptions: CuratedSSHOptions
    public var sshLogLevel: SSHLogLevel?
    public var extraSSHOptions: [String]

    public init(
        hostPatterns: [String],
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        proxyJump: String? = nil,
        dynamicForwardPort: Int? = nil,
        localPortForwardings: [LocalPortForward] = [],
        curatedSSHOptions: CuratedSSHOptions = CuratedSSHOptions(),
        sshLogLevel: SSHLogLevel? = nil,
        extraSSHOptions: [String] = []
    ) {
        self.hostPatterns = hostPatterns
        self.hostName = hostName
        self.user = user
        self.port = port
        self.proxyJump = proxyJump
        self.dynamicForwardPort = dynamicForwardPort
        self.localPortForwardings = localPortForwardings
        self.curatedSSHOptions = curatedSSHOptions
        self.sshLogLevel = sshLogLevel
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
        case "dynamicforward":
            entry.dynamicForwardPort = parseForwardPort(firstValue)
        case "localforward":
            if let forwarding = parseLocalForward(directive.values) {
                entry.localPortForwardings.append(forwarding)
            }
        case "bindaddress":
            entry.curatedSSHOptions.bindAddress = firstValue
        case "addressfamily":
            entry.curatedSSHOptions.addressFamily = parseAddressFamily(firstValue)
        case "compression":
            entry.curatedSSHOptions.compression = parseToggle(firstValue)
        case "identityfile":
            entry.curatedSSHOptions.identityFiles.append(firstValue)
        case "certificatefile":
            entry.curatedSSHOptions.certificateFiles.append(firstValue)
        case "forwardagent":
            entry.curatedSSHOptions.forwardAgent = parseToggle(firstValue)
        case "loglevel":
            entry.sshLogLevel = parseLogLevel(firstValue)
        case "identitiesonly", "gssapiauthentication", "gssapidelegatecredentials", "kbdinteractiveauthentication", "preferredauthentications":
            entry.extraSSHOptions += ["-o", "\(directive.originalKeyword)=\(directive.values.joined(separator: " "))"]
        case "proxycommand":
            entry.curatedSSHOptions.proxyCommand = directive.values.joined(separator: " ")
        default:
            break
        }
    }

    private static func parseAddressFamily(_ value: String) -> SSHAddressFamily {
        switch value.lowercased() {
        case "inet": .ipv4
        case "inet6": .ipv6
        default: .any
        }
    }

    private static func parseToggle(_ value: String) -> SSHOptionToggle {
        switch value.lowercased() {
        case "yes", "true", "on": .enabled
        case "no", "false", "off": .disabled
        default: .systemDefault
        }
    }

    private static func parseLogLevel(_ value: String) -> SSHLogLevel {
        switch value.lowercased() {
        case "debug", "debug1": .debug1
        case "debug2": .debug2
        case "debug3": .debug3
        default: .info
        }
    }

    private static func parseForwardPort(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.last.flatMap { Int($0) }
    }

    private static func parseLocalForward(_ values: [String]) -> LocalPortForward? {
        if values.count >= 2,
           let source = parseLocalForwardSource(values[0]),
           let target = parseForwardTarget(values[1]) {
            return LocalPortForward(
                bindAddress: source.bindAddress,
                localPort: source.port,
                targetHost: target.host,
                targetPort: target.port
            )
        }

        guard values.count == 1 else { return nil }
        let parts = values[0].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let localPort = Int(parts[parts.count - 3]),
              let targetPort = Int(parts[parts.count - 1]) else {
            return nil
        }
        let bindAddress = parts.count > 3 ? String(parts.dropLast(3).joined(separator: ":")) : nil
        let targetHost = String(parts[parts.count - 2])
        return LocalPortForward(bindAddress: bindAddress, localPort: localPort, targetHost: targetHost, targetPort: targetPort)
    }

    private static func parseLocalForwardSource(_ value: String) -> (bindAddress: String?, port: Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard let portText = parts.last, let port = Int(portText) else { return nil }
        let bindAddress = parts.count > 1 ? String(parts.dropLast().joined(separator: ":")) : nil
        return (bindAddress, port)
    }

    private static func parseForwardTarget(_ value: String) -> (host: String, port: Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let portText = parts.last,
              let port = Int(portText) else {
            return nil
        }
        return (String(parts.dropLast().joined(separator: ":")), port)
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
    var dynamicForwardPort: Int?
    var localPortForwardings: [LocalPortForward] = []
    var curatedSSHOptions = CuratedSSHOptions()
    var sshLogLevel: SSHLogLevel?
    var extraSSHOptions: [String] = []

    var entry: SSHConfigEntry {
        SSHConfigEntry(
            hostPatterns: hostPatterns,
            hostName: hostName,
            user: user,
            port: port,
            proxyJump: proxyJump,
            dynamicForwardPort: dynamicForwardPort,
            localPortForwardings: localPortForwardings,
            curatedSSHOptions: curatedSSHOptions,
            sshLogLevel: sshLogLevel,
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
