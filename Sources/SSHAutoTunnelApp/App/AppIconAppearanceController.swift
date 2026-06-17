import AppKit
import Foundation
import OSLog
import SSHAutoTunnelCore

@MainActor
final class AppIconAppearanceController {
    private let logger = Logger(subsystem: AppPaths.appIdentifier, category: "app-icon")
    private var appearanceObservation: NSKeyValueObservation?
    private var themeNotification: NSObjectProtocol?
    private var darkIcon: NSImage?

    func start() {
        darkIcon = loadDarkIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            Task { @MainActor in
                self?.applyIcon(for: app.effectiveAppearance)
            }
        }
        themeNotification = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyIcon(for: NSApp.effectiveAppearance)
            }
        }
    }

    func stop() {
        if let themeNotification {
            DistributedNotificationCenter.default().removeObserver(themeNotification)
        }
        themeNotification = nil
        appearanceObservation = nil
        NSApp.applicationIconImage = nil
    }

    private func applyIcon(for appearance: NSAppearance) {
        if usesDarkAppearance(appearance) {
            if let darkIcon {
                NSApp.applicationIconImage = darkIcon
            } else {
                logger.error("Dark app icon resource is missing")
                NSApp.applicationIconImage = nil
            }
        } else {
            NSApp.applicationIconImage = nil
        }
    }

    private func usesDarkAppearance(_ appearance: NSAppearance) -> Bool {
        let matches: [NSAppearance.Name] = [
            .darkAqua,
            .accessibilityHighContrastDarkAqua,
            .aqua,
            .accessibilityHighContrastAqua
        ]
        guard let bestMatch = appearance.bestMatch(from: matches) else {
            return false
        }
        return bestMatch == .darkAqua || bestMatch == .accessibilityHighContrastDarkAqua
    }

    private func loadDarkIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIconDark", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
