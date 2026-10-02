import AppKit
import UserNotifications

/// Posts user notifications and opens the linked GitHub page when one is clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = Notifier()

    /// Asks for permission (once) and starts handling clicks.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, subtitle: String = "", body: String, url: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        if let url {
            content.userInfo = ["url": url.absoluteString]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show notifications even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let string = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: string) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
