import Foundation

public struct InteractiveTerminalInstallation: Identifiable, Equatable, Sendable {
    public var app: InteractiveTerminalApp
    public var bundleIdentifier: String
    public var applicationPath: String

    public var id: InteractiveTerminalApp { app }

    public init(app: InteractiveTerminalApp, bundleIdentifier: String, applicationPath: String) {
        self.app = app
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
    }
}

public struct InteractiveTerminalOption: Identifiable, Equatable, Sendable {
    public var app: InteractiveTerminalApp
    public var isInstalled: Bool
    public var applicationPath: String?

    public var id: InteractiveTerminalApp { app }

    public init(app: InteractiveTerminalApp, isInstalled: Bool, applicationPath: String? = nil) {
        self.app = app
        self.isInstalled = isInstalled
        self.applicationPath = applicationPath
    }
}

public struct InteractiveTerminalDiscovery: Sendable {
    public var searchRoots: [URL]

    public init(searchRoots: [URL] = Self.defaultSearchRoots()) {
        self.searchRoots = searchRoots
    }

    public static func defaultSearchRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    public func discoverInstalledTerminals(fileManager: FileManager = .default) -> [InteractiveTerminalInstallation] {
        let supportedAppsByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: InteractiveTerminalApp.supportedLaunchAdapters.compactMap { app in
                app.bundleIdentifier.map { ($0, app) }
            }
        )
        var candidates: [InteractiveTerminalApp: [URL]] = [:]

        for root in searchRoots {
            for applicationURL in applicationBundleURLs(in: root, fileManager: fileManager) {
                guard let bundleIdentifier = bundleIdentifier(at: applicationURL),
                      let app = supportedAppsByBundleIdentifier[bundleIdentifier] else {
                    continue
                }
                candidates[app, default: []].append(applicationURL)
            }
        }

        return InteractiveTerminalApp.supportedLaunchAdapters.compactMap { app in
            guard let bundleIdentifier = app.bundleIdentifier,
                  let applicationURL = preferredApplicationURL(from: candidates[app] ?? []) else {
                return nil
            }
            return InteractiveTerminalInstallation(
                app: app,
                bundleIdentifier: bundleIdentifier,
                applicationPath: applicationURL.path
            )
        }
    }

    public static func options(
        for installations: [InteractiveTerminalInstallation],
        currentApp: InteractiveTerminalApp,
        includeCustom: Bool = true
    ) -> [InteractiveTerminalOption] {
        let installationsByApp = Dictionary(uniqueKeysWithValues: installations.map { ($0.app, $0) })
        var apps = InteractiveTerminalApp.supportedLaunchAdapters.filter { installationsByApp[$0] != nil }
        if currentApp != .custom && !apps.contains(currentApp) {
            apps.append(currentApp)
        }
        if includeCustom {
            apps.append(.custom)
        }

        return apps.map { app in
            if let installation = installationsByApp[app] {
                InteractiveTerminalOption(app: app, isInstalled: true, applicationPath: installation.applicationPath)
            } else {
                InteractiveTerminalOption(app: app, isInstalled: app == .custom)
            }
        }
    }

    private func applicationBundleURLs(in root: URL, fileManager: FileManager) -> [URL] {
        let standardizedRoot = root.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: standardizedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        var urls: [URL] = []
        if standardizedRoot.pathExtension == "app" {
            urls.append(standardizedRoot)
        }

        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return urls
        }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            urls.append(url.standardizedFileURL)
        }

        return urls.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func bundleIdentifier(at applicationURL: URL) -> String? {
        let infoURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleIdentifier"] as? String
    }

    private func preferredApplicationURL(from urls: [URL]) -> URL? {
        urls.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }.first
    }
}
