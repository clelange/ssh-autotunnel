import Foundation
import SSHAutoTunnelCore
import UserNotifications

final class AppNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private enum Action {
        static let reconnectTunnel = "ssh-autotunnel.reconnect-tunnel"
        static let reconnectHop = "ssh-autotunnel.reconnect-hop"
    }

    private enum Category {
        static let tunnelFailure = "ssh-autotunnel.tunnel-failure"
        static let hopFailure = "ssh-autotunnel.hop-failure"
    }

    var onReconnectTunnel: ((UUID) -> Void)?
    var onReconnectHop: ((UUID) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.tunnelFailure,
                actions: [
                    UNNotificationAction(identifier: Action.reconnectTunnel, title: "Try Again", options: [.foreground])
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.hopFailure,
                actions: [
                    UNNotificationAction(identifier: Action.reconnectHop, title: "Try Again", options: [.foreground])
                ],
                intentIdentifiers: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(event: TunnelNotificationEvent, profileID: UUID, profileName: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "\(profileName): \(message)"
        content.sound = .default
        content.userInfo = [
            "profileID": profileID.uuidString,
            "kind": event.kind.rawValue
        ]
        if event.offersTryAgainAction {
            switch event.kind {
            case .tunnel:
                content.categoryIdentifier = Category.tunnelFailure
            case .hop:
                content.categoryIdentifier = Category.hopFailure
            }
        }

        let request = UNNotificationRequest(
            identifier: "ssh-autotunnel-\(profileID.uuidString)-\(event.title)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func deliverStatusChange(kind: ConnectionKind, profileID: UUID, profileName: String, health: TunnelHealth, message: String) {
        let content = UNMutableNotificationContent()
        let subject = kind == .hop ? "Hop connection" : "Tunnel"
        content.title = "\(subject) \(health.rawValue)"
        content.body = "\(profileName): \(message)"
        content.sound = .default
        content.userInfo = [
            "profileID": profileID.uuidString,
            "kind": kind.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: "ssh-autotunnel-\(profileID.uuidString)-\(kind.rawValue)-\(health.rawValue)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let profileIDString = response.notification.request.content.userInfo["profileID"] as? String,
              let profileID = UUID(uuidString: profileIDString) else {
            return
        }

        switch response.actionIdentifier {
        case Action.reconnectTunnel:
            DispatchQueue.main.async { [onReconnectTunnel] in
                onReconnectTunnel?(profileID)
            }
        case Action.reconnectHop:
            DispatchQueue.main.async { [onReconnectHop] in
                onReconnectHop?(profileID)
            }
        default:
            return
        }
    }
}
