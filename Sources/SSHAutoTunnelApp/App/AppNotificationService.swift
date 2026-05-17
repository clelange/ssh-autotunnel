import Foundation
import SSHAutoTunnelCore
import UserNotifications

final class AppNotificationService {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(event: TunnelNotificationEvent, profileName: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "\(profileName): \(message)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ssh-autotunnel-\(profileName)-\(event.title)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
