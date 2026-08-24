import Foundation
import UserNotifications

/// Fennec's only outbound channel.
///
/// The design rule here is proportionality. A successful automatic repair is
/// the one notification the product exists to deliver, so it is quiet — no
/// sound, no badge, a banner that says what happened and gets out of the way.
/// A *failed* repair, or a crackle Fennec was not allowed to fix, is the only
/// case where the user has to do something, so those get a sound and an
/// action button.
@MainActor
final class NotificationController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Action {
        static let repair = "REPAIR_CORE_AUDIO"
        static let ignore = "IGNORE_CRACKLE_SIGNAL"
    }

    private enum Category {
        static let detected = "CRACKLE_DETECTED"
        static let repaired = "AUDIO_REPAIRED"
        static let failed = "REPAIR_FAILED"
    }

    var onRepairRequested: (() -> Void)?

    /// `false` until the user has answered the system prompt, or when they
    /// said no. The UI uses this to explain why nothing appears.
    @Published private(set) var isAuthorized = false
    @Published private(set) var authorizationChecked = false

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.detected,
                actions: [
                    UNNotificationAction(identifier: Action.repair, title: "Repair Now", options: [.foreground]),
                    UNNotificationAction(identifier: Action.ignore, title: "Ignore", options: [])
                ],
                intentIdentifiers: [],
                options: []
            ),
            // Nothing to do — Fennec already handled it. A success banner
            // with buttons would be asking for work the user does not have.
            UNNotificationCategory(
                identifier: Category.repaired,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Category.failed,
                actions: [
                    UNNotificationAction(identifier: Action.repair, title: "Try Again", options: [.foreground])
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                NSLog("Fennec notification authorization error: %@", error.localizedDescription)
            }
            Task { @MainActor [weak self] in
                self?.isAuthorized = granted
                self?.authorizationChecked = true
            }
        }
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor [weak self] in
                self?.isAuthorized = granted
                self?.authorizationChecked = true
            }
        }
    }

    /// The headline moment: Fennec already fixed it, here is what it fixed.
    func postRepairResult(_ record: RepairRecord) {
        let content = UNMutableNotificationContent()
        content.title = RepairCopy.notificationTitle(for: record)
        content.body = RepairCopy.notificationBody(for: record)

        if record.succeeded {
            content.categoryIdentifier = Category.repaired
            // No sound. Fennec just interrupted the user's audio once; it is
            // not going to interrupt it again to take a bow.
            content.interruptionLevel = .passive
        } else {
            content.categoryIdentifier = Category.failed
            content.sound = .default
        }

        post(content, prefix: "repair")
    }

    /// A crackle Fennec detected but did not repair. Always actionable —
    /// something is switched off, protected, or cooling down.
    func postUnrepairedDetection(reason: String, blocker: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Crackling detected"
        content.body = [reason, blocker].compactMap { $0 }.joined(separator: " ")
        content.categoryIdentifier = Category.detected
        content.sound = .default
        post(content, prefix: "detection")
    }

    private func post(_ content: UNMutableNotificationContent, prefix: String) {
        let request = UNNotificationRequest(
            identifier: "\(prefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Fennec could not post a notification: %@", error.localizedDescription)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch identifier {
            case Action.repair:
                self.onRepairRequested?()
            default:
                break
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when Fennec is frontmost; the user is usually
        // looking at something else entirely when this fires.
        let hasSound = notification.request.content.sound != nil
        completionHandler(hasSound ? [.banner, .sound] : [.banner])
    }
}
