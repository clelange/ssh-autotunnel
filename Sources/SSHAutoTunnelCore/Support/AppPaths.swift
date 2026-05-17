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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func configurationURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("config.json")
    }

    public static func pacCopyURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("proxy.pac")
    }
}
