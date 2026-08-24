import Foundation
import UserNotifications

final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let repairActionIdentifier = "REPAIR_CORE_AUDIO"
    static let ignoreActionIdentifier = "IGNORE_CRACKLE_SIGNAL"
    private static let detectionCategoryIdentifier = "CRACKLE_DETECTED"

    var onRepairRequested: (() -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let repair = UNNotificationAction(
            identifier: Self.repairActionIdentifier,
            title: "Repair Audio",
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.ignoreActionIdentifier,
            title: "Ignore",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.detectionCategoryIdentifier,
            actions: [repair, ignore],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("Fennec notification authorization error: %@", error.localizedDescription)
            }
        }
    }

    func postDetection(reason: String, automaticRepairWasSkipped: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Possible audio crackle detected"
        content.body = automaticRepairWasSkipped
            ? "\(reason) Automatic repair was skipped."
            : reason
        content.categoryIdentifier = Self.detectionCategoryIdentifier
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "detection-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func postRepairResult(success: Bool, message: String) {
        let content = UNMutableNotificationContent()
        content.title = success ? "Core Audio repaired" : "Audio repair failed"
        content.body = message
        if !success { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: "repair-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.repairActionIdentifier {
            Task { @MainActor [weak self] in
                self?.onRepairRequested?()
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
