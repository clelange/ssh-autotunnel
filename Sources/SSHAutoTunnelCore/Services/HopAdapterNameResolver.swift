import Foundation

public struct HopAdapterProfileAlias: Equatable, Sendable {
    public var profileID: UUID
    public var profileName: String
    public var endpoint: HopEndpointKey
    public var adapterHost: String

    public init(profileID: UUID, profileName: String, endpoint: HopEndpointKey, adapterHost: String) {
        self.profileID = profileID
        self.profileName = profileName
        self.endpoint = endpoint
        self.adapterHost = adapterHost
    }
}

public struct HopAdapterEndpointAliases: Equatable, Sendable {
    public var endpoint: HopEndpointKey
    public var preferredAdapterHost: String
    public var adapterHosts: [String]
    public var currentAdapterHosts: [String]
    public var profileNames: [String]

    public init(
        endpoint: HopEndpointKey,
        preferredAdapterHost: String,
        adapterHosts: [String],
        currentAdapterHosts: [String],
        profileNames: [String]
    ) {
        self.endpoint = endpoint
        self.preferredAdapterHost = preferredAdapterHost
        self.adapterHosts = adapterHosts
        self.currentAdapterHosts = currentAdapterHosts
        self.profileNames = profileNames
    }
}

public struct HopAdapterAliasCatalog: Equatable, Sendable {
    public var profiles: [HopAdapterProfileAlias]
    public var endpoints: [HopAdapterEndpointAliases]

    public init(profiles: [HopAdapterProfileAlias], endpoints: [HopAdapterEndpointAliases]) {
        self.profiles = profiles
        self.endpoints = endpoints
    }

    public func adapterHost(for profileID: UUID) -> String? {
        profiles.first { $0.profileID == profileID }?.adapterHost
    }

    public func aliases(for endpoint: HopEndpointKey) -> HopAdapterEndpointAliases? {
        endpoints.first { $0.endpoint == endpoint }
    }
}

public enum HopAdapterNameResolver {
    public static let adapterPrefix = "ssh-autotunnel-hop-"

    public static func adapterHostBase(profileName: String) -> String {
        adapterPrefix + slug(profileName, fallback: "profile")
    }

    public static func resolve(
        profiles: [TunnelProfile],
        historicalAliases: [HopEndpointKey: Set<String>] = [:]
    ) -> HopAdapterAliasCatalog {
        var records = profiles.compactMap { profile -> AdapterRecord? in
            guard let endpoint = try? HopEndpointKey(profile: profile) else { return nil }
            return AdapterRecord(profile: profile, endpoint: endpoint)
        }
        records.sort {
            let nameOrder = $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.profile.id.uuidString < $1.profile.id.uuidString
        }

        var candidates = records.map { adapterHostBase(profileName: $0.profile.name) }
        let reservations = AdapterAliasReservations(
            legacyHosts: Set(records.map { $0.endpoint.adapterHost }),
            historicalAliases: historicalAliases
        )
        disambiguate(&candidates, records: records, reservations: reservations) { record in
            slug(record.endpoint.host, fallback: "host")
        }
        disambiguate(&candidates, records: records, reservations: reservations) { record in
            let user = slug(record.endpoint.user, fallback: "user")
            return "\(user)-\(record.endpoint.port)"
        }
        disambiguateWithOrdinals(&candidates, records: records, reservations: reservations)

        let profileAliases = zip(records, candidates).map { record, alias in
            HopAdapterProfileAlias(
                profileID: record.profile.id,
                profileName: record.profile.name,
                endpoint: record.endpoint,
                adapterHost: alias
            )
        }
        let grouped = Dictionary(grouping: profileAliases, by: \.endpoint)
        let endpointAliases = grouped.map { endpoint, aliases -> HopAdapterEndpointAliases in
            let current = Array(Set(aliases.map(\.adapterHost))).sorted()
            let retained = Set(historicalAliases[endpoint, default: []]
                .filter(isSafeAdapterHost)
                .filter { !reservations.conflicts(alias: $0, endpoint: endpoint) })
                .subtracting(current)
                .sorted()
            let all = current + retained + [endpoint.adapterHost]
            return HopAdapterEndpointAliases(
                endpoint: endpoint,
                preferredAdapterHost: current[0],
                adapterHosts: all,
                currentAdapterHosts: current,
                profileNames: Array(Set(aliases.map(\.profileName))).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            )
        }.sorted { $0.preferredAdapterHost < $1.preferredAdapterHost }

        return HopAdapterAliasCatalog(profiles: profileAliases, endpoints: endpointAliases)
    }

    public static func isSafeAdapterHost(_ value: String) -> Bool {
        guard value.hasPrefix(adapterPrefix), value.count > adapterPrefix.count else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x61 && scalar.value <= 0x7a)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar.value == 0x2d
        }
    }

    private static func slug(_ value: String, fallback: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased(with: Locale(identifier: "en_US_POSIX"))
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            let isLetter = scalar.value >= 0x61 && scalar.value <= 0x7a
            let isNumber = scalar.value >= 0x30 && scalar.value <= 0x39
            if isLetter || isNumber {
                if pendingDash, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return result.isEmpty ? fallback : result
    }

    private static func disambiguate(
        _ candidates: inout [String],
        records: [AdapterRecord],
        reservations: AdapterAliasReservations,
        suffix: (AdapterRecord) -> String
    ) {
        for indices in collisionGroups(candidates, records: records, reservations: reservations) {
            for index in indices {
                candidates[index] += "-" + suffix(records[index])
            }
        }
    }

    private static func disambiguateWithOrdinals(
        _ candidates: inout [String],
        records: [AdapterRecord],
        reservations: AdapterAliasReservations
    ) {
        while true {
            let groups = collisionGroups(candidates, records: records, reservations: reservations)
            guard !groups.isEmpty else { return }
            for indices in groups {
                let endpoints = Array(Set(indices.map { records[$0].endpoint })).sorted(by: endpointSort)
                let ordinals = Dictionary(
                    uniqueKeysWithValues: endpoints.enumerated().map { ($0.element, $0.offset + 1) }
                )
                for index in indices {
                    candidates[index] += "-\(ordinals[records[index].endpoint]!)"
                }
            }
        }
    }

    private static func collisionGroups(
        _ candidates: [String],
        records: [AdapterRecord],
        reservations: AdapterAliasReservations
    ) -> [[Int]] {
        let grouped = Dictionary(grouping: candidates.indices, by: { candidates[$0] })
        return grouped.values.compactMap { indices in
            let conflicting = indices.filter { index in
                reservations.conflicts(alias: candidates[index], endpoint: records[index].endpoint)
            }
            // An established owner keeps its alias; only the newcomers move.
            if !conflicting.isEmpty { return conflicting }
            return Set(indices.map { records[$0].endpoint }).count > 1 ? indices : nil
        }
    }

    private static func endpointSort(_ lhs: HopEndpointKey, _ rhs: HopEndpointKey) -> Bool {
        if lhs.host != rhs.host { return lhs.host < rhs.host }
        if lhs.user != rhs.user { return lhs.user < rhs.user }
        return lhs.port < rhs.port
    }
}

private struct AdapterAliasReservations {
    var legacyHosts: Set<String>
    var historicalOwners: [String: Set<HopEndpointKey>] = [:]

    init(legacyHosts: Set<String>, historicalAliases: [HopEndpointKey: Set<String>]) {
        self.legacyHosts = legacyHosts
        for (endpoint, aliases) in historicalAliases {
            for alias in aliases where HopAdapterNameResolver.isSafeAdapterHost(alias) {
                historicalOwners[alias, default: []].insert(endpoint)
            }
        }
    }

    func conflicts(alias: String, endpoint: HopEndpointKey) -> Bool {
        if legacyHosts.contains(alias) { return true }
        guard let owners = historicalOwners[alias] else { return false }
        return owners != [endpoint]
    }
}

private struct AdapterRecord {
    var profile: TunnelProfile
    var endpoint: HopEndpointKey
}
