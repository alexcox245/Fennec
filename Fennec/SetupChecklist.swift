import Foundation

/// One thing standing between the user and a Fennec that works unattended.
struct SetupStep: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Install the root helper so a repair needs no password prompt.
        case helper
        /// Approve the helper in System Settings once macOS has staged it.
        case helperApproval
        /// Start with the Mac, so Fennec is listening before the user is.
        case loginItem
        /// Allow the banner that says a repair happened.
        case notifications
    }

    let kind: Kind
    let title: String
    /// The full explanation, for Settings and the first-run window.
    let detail: String
    /// One line, for the popover. The popover is 384 pt wide and the setup
    /// card is the first thing a new user sees — three five-line paragraphs
    /// there is not onboarding, it is a wall.
    let compactDetail: String
    let actionTitle: String
    let isComplete: Bool
    /// Required steps block unattended repair. Optional ones only make it
    /// quieter or more visible.
    let isRequired: Bool

    var id: String { kind.rawValue }
}

/// The readiness model behind both the popover's "Finish setup" card and the
/// first-run window.
///
/// It is pure and total: given the three system states, it always returns the
/// same four steps in the same order, each either complete or not. Views
/// filter; they never decide.
enum SetupChecklist {

    static func steps(
        helper: RepairHelperState,
        loginItem: LoginItemState,
        notificationsAuthorized: Bool
    ) -> [SetupStep] {
        [
            helperStep(for: helper),
            loginItemStep(for: loginItem),
            notificationStep(authorized: notificationsAuthorized)
        ]
    }

    /// Steps the user still has to act on, most blocking first.
    static func remaining(
        helper: RepairHelperState,
        loginItem: LoginItemState,
        notificationsAuthorized: Bool
    ) -> [SetupStep] {
        steps(helper: helper, loginItem: loginItem, notificationsAuthorized: notificationsAuthorized)
            .filter { !$0.isComplete }
            .sorted { lhs, rhs in
                lhs.isRequired == rhs.isRequired ? false : lhs.isRequired
            }
    }

    /// True when Fennec can do its whole job without asking for anything.
    static func isReady(helper: RepairHelperState, loginItem: LoginItemState) -> Bool {
        helper.isReachable && loginItem.isEnabled
    }

    /// The single line the popover shows when setup is not finished.
    static func summary(
        helper: RepairHelperState,
        loginItem: LoginItemState,
        notificationsAuthorized: Bool
    ) -> String {
        let outstanding = remaining(
            helper: helper,
            loginItem: loginItem,
            notificationsAuthorized: notificationsAuthorized
        )
        guard !outstanding.isEmpty else {
            return "Fennec is set up. It starts with your Mac and repairs without asking."
        }
        let required = outstanding.filter(\.isRequired).count
        if required == 0 {
            return "Fennec will repair automatically. \(outstanding.count) optional step\(outstanding.count == 1 ? "" : "s") left."
        }
        return "\(required) step\(required == 1 ? "" : "s") left before Fennec can repair on its own."
    }

    // MARK: Individual steps

    private static func helperStep(for helper: RepairHelperState) -> SetupStep {
        switch helper {
        case .awaitingApproval:
            return SetupStep(
                kind: .helperApproval,
                title: "Allow Fennec in the background",
                detail: "macOS staged Fennec's repair helper and is waiting for you to switch it on under Login Items & Extensions.",
                compactDetail: "macOS is waiting for you to allow it.",
                actionTitle: "Open Login Items…",
                isComplete: false,
                isRequired: true
            )
        case .enabled(let reachable):
            return SetupStep(
                kind: .helper,
                title: "Repair without a password prompt",
                detail: reachable
                    ? "The repair helper is installed and answering."
                    : "The helper is installed but is not answering. Recheck it in Settings.",
                compactDetail: reachable ? "Installed and answering." : "Installed, but not answering.",
                actionTitle: reachable ? "Installed" : "Recheck",
                isComplete: reachable,
                isRequired: true
            )
        case .notConfigured:
            return SetupStep(
                kind: .helper,
                title: "Repair without a password prompt",
                detail: "Fennec installs a small root helper that can do exactly one thing: restart Core Audio. Without it, every repair asks for your password.",
                compactDetail: "A root helper that can only restart Core Audio.",
                actionTitle: "Enable Helper",
                isComplete: false,
                isRequired: true
            )
        case .unavailable(let message):
            return SetupStep(
                kind: .helper,
                title: "Repair without a password prompt",
                detail: message,
                compactDetail: message,
                actionTitle: "Try Again",
                isComplete: false,
                isRequired: true
            )
        }
    }

    private static func loginItemStep(for loginItem: LoginItemState) -> SetupStep {
        switch loginItem {
        case .enabled:
            return SetupStep(
                kind: .loginItem,
                title: "Start with your Mac",
                detail: loginItem.detail,
                compactDetail: "Fennec starts with your Mac.",
                actionTitle: "On",
                isComplete: true,
                isRequired: true
            )
        case .requiresApproval:
            return SetupStep(
                kind: .loginItem,
                title: "Start with your Mac",
                detail: loginItem.detail,
                compactDetail: "macOS is waiting for you to allow it.",
                actionTitle: "Open Login Items…",
                isComplete: false,
                isRequired: true
            )
        case .notRegistered, .notFound, .unknown:
            return SetupStep(
                kind: .loginItem,
                title: "Start with your Mac",
                detail: "Crackling turns up during long builds and exports — usually while you are not watching. Fennec has to already be running to catch the first signal.",
                compactDetail: "Fennec has to be running to catch the first signal.",
                actionTitle: "Turn On",
                isComplete: false,
                isRequired: true
            )
        }
    }

    private static func notificationStep(authorized: Bool) -> SetupStep {
        SetupStep(
            kind: .notifications,
            title: "Tell me when you fix something",
            detail: authorized
                ? "Fennec will post a quiet banner after each repair."
                : "Without notification permission a repair is completely silent — which is nice, right up until you wonder whether Fennec is doing anything at all.",
            compactDetail: authorized
                ? "A quiet banner after each repair."
                : "Otherwise a repair is completely silent.",
            actionTitle: authorized ? "Allowed" : "Open Notifications…",
            isComplete: authorized,
            isRequired: false
        )
    }
}
