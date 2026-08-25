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

    /// Who has to act for this step to complete.
    ///
    /// First run reads this to decide what it may switch on by itself and what
    /// it has to ask a person for, and the first-run window prints it so the
    /// distinction is visible rather than implied.
    enum Grant: String, Sendable {
        /// Fennec can turn it on with no dialog at all. It does, at first run.
        case fennec
        /// macOS raises its own prompt — once, for the lifetime of the install.
        /// Spending it is a decision, not a formality.
        case systemPrompt
        /// An administrator password, and an approval in System Settings. The
        /// only thing Fennec asks a person for.
        case administrator

        /// One line saying who is being asked, and how often.
        var note: String {
            switch self {
            case .fennec:
                return "Fennec turned this on for you. Switch it off whenever you like."
            case .systemPrompt:
                return "macOS asks once, and never asks again."
            case .administrator:
                return "The one thing Fennec needs you for."
            }
        }
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

    var grant: Grant {
        switch kind {
        case .helper, .helperApproval: return .administrator
        case .loginItem: return .fennec
        case .notifications: return .systemPrompt
        }
    }
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
                title: "Your administrator password, once",
                detail: "Fennec installs a small root helper that can do exactly one thing: restart Core Audio. macOS will ask for your administrator password, and then for your approval under Login Items & Extensions. Without it Fennec still detects crackling but cannot repair on its own — you press Repair Audio Now and type your password every time.",
                compactDetail: "Without it, Fennec detects but cannot repair on its own.",
                actionTitle: "Install Helper…",
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

    // MARK: First run

    /// What Fennec needs, stated before any of it is asked for. Invariant: it
    /// is the same three things on every Mac, in the order the window lists
    /// them.
    static let whatItNeeds = """
        Three things make that work. Fennec has to start with your Mac, because crackling turns up \
        during long builds and exports and it has to already be running to catch the first signal. \
        It needs permission to post a banner, because a repair you never hear about is \
        indistinguishable from a product that does nothing. And restarting Core Audio needs \
        administrator rights, because that is what restarting a system daemon costs.
        """

    /// The line under that one, which has to stay true as the states change.
    static func firstRunStatus(
        helper: RepairHelperState,
        loginItem: LoginItemState,
        notificationsAuthorized: Bool
    ) -> String {
        let helperReady = helper.isReachable
        switch (helperReady, loginItem.isEnabled && notificationsAuthorized) {
        case (true, true):
            return "All three are in place. Fennec is listening."
        case (false, true):
            return "Fennec set up the first two itself. Your administrator password is the only thing left."
        case (true, false):
            return "Fennec can already repair on its own. What is left is listed under What Fennec needs from you."
        case (false, false):
            return "What Fennec still needs is listed under What Fennec needs from you, most blocking first."
        }
    }
}

/// What Fennec switches on for itself the first time it runs.
///
/// The rule is one sentence long: **Fennec grants what costs the user nothing
/// and asks for what costs them something.** Registering a login item raises no
/// dialog and is undone with one switch, so making a person hunt for it buys
/// nothing but an unconfigured install. Root is the opposite — it is the whole
/// reason the first-run window is a consent record — so it is never in this
/// list, and `FirstRunDefaultsTests` says so out loud.
///
/// Pure and total, so the decision can be read and tested without a live
/// `SMAppService`.
enum FirstRunDefaults {

    /// Ordered: the silent one first, so the system notification prompt is the
    /// only thing on screen when it arrives.
    enum Action: String, Sendable, Equatable {
        /// `SMAppService.mainApp.register()` — no dialog, no password.
        case enableLoginItem
        /// The one `UNUserNotificationCenter` prompt macOS ever allows.
        case requestNotificationPermission
    }

    static func actions(
        loginItem: LoginItemState,
        notificationsAnswered: Bool
    ) -> [Action] {
        var actions: [Action] = []

        switch loginItem {
        case .notRegistered, .notFound:
            actions.append(.enableLoginItem)
        case .enabled:
            // Already on. Registering again is a no-op that can still throw.
            break
        case .requiresApproval:
            // macOS holds the registration and is waiting on a human in System
            // Settings. Re-registering does not move that, and Fennec must not
            // open System Settings uninvited on the first launch.
            break
        case .unknown:
            break
        }

        if !notificationsAnswered {
            actions.append(.requestNotificationPermission)
        }

        return actions
    }
}
