import Foundation

enum SSHConnectionLaunchOrigin {
    case userInitiated
    case automatic
}

struct SSHAutomaticAttemptLimitError: LocalizedError {
    var endpoint: SSHConnectionEndpoint

    var errorDescription: String? {
        "Automatic reconnect stopped: \(TunnelLifecyclePolicy.endpointAttemptLimit) SSH connection attempts to \(endpoint.displayName) occurred within 10 minutes. No more automatic attempts will be made."
    }
}

public struct SSHConnectionEndpoint: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
    }

    public init(profile: TunnelProfile) {
        self.init(host: profile.host, port: profile.sshPort)
    }

    public init(hopEndpoint: HopEndpointKey) {
        self.init(host: hopEndpoint.host, port: hopEndpoint.port)
    }

    public var displayName: String {
        "\(host):\(port)"
    }
}

public final class SSHConnectionAttemptLedger: @unchecked Sendable {
    public struct Reservation: Hashable, Sendable {
        fileprivate var id: UUID
        fileprivate var endpoint: SSHConnectionEndpoint
    }

    private struct Entry {
        var id: UUID
        var date: Date
    }

    private let limit: Int
    private let window: TimeInterval
    private let lock = NSLock()
    private var entries: [SSHConnectionEndpoint: [Entry]] = [:]

    public init(
        limit: Int = TunnelLifecyclePolicy.endpointAttemptLimit,
        window: TimeInterval = TunnelLifecyclePolicy.endpointAttemptWindow
    ) {
        self.limit = max(1, limit)
        self.window = max(0, window)
    }

    public func reserveAutomaticAttempt(to endpoint: SSHConnectionEndpoint, at date: Date = Date()) -> Reservation? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(at: date)
        guard entries[endpoint, default: []].count < limit else { return nil }
        let reservation = Reservation(id: UUID(), endpoint: endpoint)
        entries[endpoint, default: []].append(Entry(id: reservation.id, date: date))
        return reservation
    }

    public func recordUserInitiatedAttempt(to endpoint: SSHConnectionEndpoint, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(at: date)
        entries[endpoint, default: []].append(Entry(id: UUID(), date: date))
    }

    public func cancel(_ reservation: Reservation) {
        lock.lock()
        defer { lock.unlock() }
        entries[reservation.endpoint]?.removeAll { $0.id == reservation.id }
        if entries[reservation.endpoint]?.isEmpty == true {
            entries[reservation.endpoint] = nil
        }
    }

    public func recentAttemptCount(to endpoint: SSHConnectionEndpoint, at date: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(at: date)
        return entries[endpoint]?.count ?? 0
    }

    private func pruneLocked(at date: Date) {
        for endpoint in Array(entries.keys) {
            entries[endpoint]?.removeAll { date.timeIntervalSince($0.date) >= window }
            if entries[endpoint]?.isEmpty == true {
                entries[endpoint] = nil
            }
        }
    }
}
