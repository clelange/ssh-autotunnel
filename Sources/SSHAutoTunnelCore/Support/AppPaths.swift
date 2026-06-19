import Foundation

public enum AppPaths {
    public static let appIdentifier = "dev.clange.ssh-autotunnel"

    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("SSHAutoTunnel", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        return directory
    }

    public static func configurationURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("config.json")
    }

    public static func pacCopyURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("proxy.pac")
    }

    public static func proxySnapshotURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("system-proxy-snapshot.json")
    }

    public static func interactiveSessionDirectory() throws -> URL {
        let directory = try applicationSupportDirectory()
            .appendingPathComponent("interactive-sessions", isDirectory: true)
        try FileProtection.protectDirectory(directory)
        return directory
    }

    public static func tunnelProcessRegistryURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("tunnel-processes.json")
    }
}
