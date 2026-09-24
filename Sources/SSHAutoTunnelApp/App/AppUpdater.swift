import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var startupError: String?

    let isEnabled: Bool
    private var controller: SPUStandardUpdaterController?

    override init() {
        // Development and ad-hoc bundles must not replace themselves with a release.
        isEnabled = Bundle.main.object(forInfoDictionaryKey: "SSHAutoTunnelUpdatesEnabled") as? Bool == true
        super.init()
    }

    func start() {
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheckedAt)
        do {
            try updater.start()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
