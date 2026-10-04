import Foundation

/// One thing standing between the user and a Fennec that works unattended.
struct SetupStep: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Put the bundle where registrations survive: Applications.
        case install
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
    /// card is the first thing a new user sees; three five-line paragraphs
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
        notificationsAuthorized: Bool,
        repairMode: RepairMode = .automatic,
        location: InstallLocation = .applications
    ) -> [SetupStep] {
        [
            installStep(for: location, required: repairMode == .automatic),
            helperStep(for: helper, required: repairMode == .automatic),
            loginItemStep(for: loginItem),
            notificationStep(
                authorized: notificationsAuthorized,
                required: repairMode == .askFirst
            )
        ]
    }

    /// Steps the user still has to act on, most blocking first.
    static func remaining(
        helper: RepairHelperState,
        loginItem: LoginItemState,
        notificationsAuthorized: Bool,
        repairMode: RepairMode = .automatic,
        location: InstallLocation = .applications
    ) -> [SetupStep] {
        steps(
            helper: helper,
            loginItem: loginItem,
            notificationsAuthorized: notificationsAuthorized,
            repairMode: repairMode,
            location: location
        )
            .filter { !$0.isComplete && $0.isRequired }
            .sorted { lhs, rhs in
                lhs.isRequired == rhs.isRequired ? false : lhs.isRequired
            }
    }

    /// True when the chosen mode can respond to a detected fault.
    static func isReady(
        helper: RepairHelperState,
        loginItem: LoginItemState,
        notificationsAuthorized: Bool,
        repairMode: RepairMode = .automatic,
        location: InstallLocation = .applications
    ) -> Bool {
        switch repairMode {
        case .automatic:
            return helper.isReachable && installStep(for: location, required: true).isComplete
        case .askFirst: return notificationsAuthorized
        }
    }

    /// The single line the popover shows when setup is not finished.
    static func summary(
        helper: RepairHelperState,
        loginItem: LoginItemState,
        notificationsAuthorized: Bool,
        repairMode: RepairMode = .automatic,
        location: InstallLocation = .applications
    ) -> String {
        let outstanding = remaining(
            helper: helper,
            loginItem: loginItem,
            notificationsAuthorized: notificationsAuthorized,
            repairMode: repairMode,
            location: location
        )
        guard !outstanding.isEmpty else {
            return repairMode == .automatic
                ? "Automatic repair is ready."
                : "Ask me first is ready."
        }
        let required = outstanding.count
        return repairMode == .askFirst
            ? "Allow notifications so Fennec can ask before repairing."
            : "\(required) step\(required == 1 ? "" : "s") before automatic repair is ready."
    }

    // MARK: Individual steps

    private static func installStep(for location: InstallLocation, required: Bool) -> SetupStep {
        switch location {
        case .applications:
            return SetupStep(
                kind: .install,
                title: "Live in Applications",
                detail: "Fennec is in your Applications folder, where macOS keeps its registrations pointed at the right bundle.",
                compactDetail: "Installed in Applications.",
                actionTitle: "Installed",
                isComplete: true,
                isRequired: required
            )
        case .developmentBuild:
            return SetupStep(
                kind: .install,
                title: "Live in Applications",
                detail: "This build runs from Xcode's build folder, so every registration breaks when the build is replaced. Fine for development; move it before relying on it.",
                compactDetail: "Development build. Registrations break on rebuild.",
                actionTitle: "Move to Applications",
                isComplete: false,
                isRequired: false
            )
        case .elsewhere(let folder):
            return SetupStep(
                kind: .install,
                title: "Live in Applications",
                detail: "Fennec is running from \(folder). macOS ties the helper and login item to the app's location, so moving it later silently breaks both. One click copies Fennec to Applications and relaunches it there, or drag the icon into Applications yourself.",
                compactDetail: "Running from \(folder); registrations will break.",
                actionTitle: "Move to Applications",
                isComplete: false,
                isRequired: required
            )
        }
    }

    private static func helperStep(for helper: RepairHelperState, required: Bool) -> SetupStep {
        switch helper {
        case .awaitingApproval:
            return SetupStep(
                kind: .helperApproval,
                title: "Allow the repair helper",
                detail: "macOS is waiting for you to allow Fennec under Login Items & Extensions.",
                compactDetail: "macOS is waiting for approval.",
                actionTitle: "Open Login Items…",
                isComplete: false,
                isRequired: required
            )
        case .enabled(let reachable):
            return SetupStep(
                kind: .helper,
                title: "Repair helper",
                detail: reachable
                    ? "The approved helper is ready."
                    : "The approved helper is not answering. Rebuild its registration to reconnect it.",
                compactDetail: reachable ? "Approved and ready." : "Approved, but not answering.",
                actionTitle: reachable ? "Ready" : "Reconnect",
                isComplete: reachable,
                isRequired: required
            )
        case .notConfigured:
            return SetupStep(
                kind: .helper,
                title: "Allow the repair helper",
                detail: "Automatic repair uses a small helper that needs your approval. Without it, Fennec asks before each repair.",
                compactDetail: "Fennec will ask before repairing.",
                actionTitle: "Enable Helper",
                isComplete: false,
                isRequired: required
            )
        case .unavailable(let message):
            return SetupStep(
                kind: .helper,
                title: "Repair helper",
                detail: message,
                compactDetail: message,
                actionTitle: "Try Again",
                isComplete: false,
                isRequired: required
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
                isRequired: false
            )
        case .requiresApproval:
            return SetupStep(
                kind: .loginItem,
                title: "Start with your Mac",
                detail: loginItem.detail,
                compactDetail: "macOS is waiting for you to allow it.",
                actionTitle: "Open Login Items…",
                isComplete: false,
                isRequired: false
            )
        case .notRegistered, .notFound, .unknown:
            return SetupStep(
                kind: .loginItem,
                title: "Start with your Mac",
                detail: "Crackling turns up during long builds and exports, usually while you are not watching. Fennec has to already be running to catch the first signal.",
                compactDetail: "Fennec has to be running to catch the first signal.",
                actionTitle: "Turn On",
                isComplete: false,
                isRequired: false
            )
        }
    }

    private static func notificationStep(authorized: Bool, required: Bool) -> SetupStep {
        SetupStep(
            kind: .notifications,
            title: required ? "Allow repair requests" : "Tell me when you fix something",
            detail: authorized
                ? (required
                    ? "Fennec will ask by notification before each detected repair."
                    : "Fennec will post a quiet banner after each repair.")
                : (required
                    ? "Fennec needs notifications to ask before a detected repair. Repair Audio Now remains available."
                    : "Without notifications, automatic repairs still work. Fennec records each result in Activity."),
            compactDetail: authorized
                ? (required ? "Fennec can ask before repairing." : "A quiet banner after each repair.")
                : (required ? "Allow notifications for repair requests." : "Repair results stay in Activity."),
            actionTitle: authorized ? "Allowed" : "Open Notifications…",
            isComplete: authorized,
            isRequired: required
        )
    }
}

/// Coalesces detections into one user-visible fault episode. A dismissal is
/// persisted until successful log coverage confirms a full quiet minute while
/// output has recently been active; a timer or a failed poll cannot re-arm it.
struct FaultEpisodePolicy {
    static let quietInterval: TimeInterval = 60

    private enum Key {
        static let episodeID = "faultEpisodeID"
        static let lastSignalAt = "faultEpisodeLastSignalAt"
        static let suppressedEpisodeID = "faultEpisodeSuppressedID"
    }

    private let defaults: UserDefaults
    private(set) var episodeID: UUID?
    private(set) var lastSignalAt: Date?
    private(set) var suppressedEpisodeID: UUID?
    private var quietCoverageStart: Date?
    private var lastCoverageThrough: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        episodeID = defaults.string(forKey: Key.episodeID).flatMap(UUID.init(uuidString:))
        lastSignalAt = defaults.object(forKey: Key.lastSignalAt) as? Date
        suppressedEpisodeID = defaults.string(forKey: Key.suppressedEpisodeID).flatMap(UUID.init(uuidString:))
        if episodeID == nil {
            defaults.removeObject(forKey: Key.lastSignalAt)
            defaults.removeObject(forKey: Key.suppressedEpisodeID)
        }
    }

    @discardableResult
    mutating func noteSignal(at date: Date) -> UUID {
        let id = episodeID ?? UUID()
        episodeID = id
        if lastSignalAt.map({ date > $0 }) ?? true {
            lastSignalAt = date
        }
        if let lastCoverageThrough, date >= lastCoverageThrough {
            quietCoverageStart = date
        }
        persist()
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { episodeID == id }

    func mayPrompt(for id: UUID) -> Bool {
        episodeID == id && suppressedEpisodeID != id
    }

    mutating func suppress(_ id: UUID) {
        guard episodeID == id else { return }
        suppressedEpisodeID = id
        persist()
    }

    /// A different output means the old prompt and its dismissal no longer
    /// describe the signal the user is hearing.
    mutating func invalidateForOutputChange() {
        episodeID = nil
        lastSignalAt = nil
        suppressedEpisodeID = nil
        quietCoverageStart = nil
        lastCoverageThrough = nil
        defaults.removeObject(forKey: Key.episodeID)
        defaults.removeObject(forKey: Key.lastSignalAt)
        defaults.removeObject(forKey: Key.suppressedEpisodeID)
    }

    /// `from`/`through` describe a successfully enumerated interval from the
    /// unified log. A later signal moves the beginning of the quiet interval.
    /// The interval is deliberately runtime-only; after a relaunch Fennec asks
    /// for a fresh covered minute before presenting another prompt.
    @discardableResult
    mutating func observeSuccessfulCoverage(from: Date, through: Date) -> UUID? {
        guard let id = episodeID, let lastSignalAt, through >= from else { return nil }

        if let lastCoverageThrough, from.timeIntervalSince(lastCoverageThrough) > 10 {
            quietCoverageStart = nil
        }
        if let lastCoverageThrough, lastSignalAt >= lastCoverageThrough {
            quietCoverageStart = max(from, lastSignalAt)
        }
        if quietCoverageStart == nil {
            quietCoverageStart = max(from, lastSignalAt)
        }
        lastCoverageThrough = through

        guard let quietCoverageStart,
              through.timeIntervalSince(quietCoverageStart) >= Self.quietInterval else { return nil }

        episodeID = nil
        self.lastSignalAt = nil
        suppressedEpisodeID = nil
        self.quietCoverageStart = nil
        lastCoverageThrough = nil
        defaults.removeObject(forKey: Key.episodeID)
        defaults.removeObject(forKey: Key.lastSignalAt)
        defaults.removeObject(forKey: Key.suppressedEpisodeID)
        return id
    }

    private func persist() {
        defaults.set(episodeID?.uuidString, forKey: Key.episodeID)
        defaults.set(lastSignalAt, forKey: Key.lastSignalAt)
        defaults.set(suppressedEpisodeID?.uuidString, forKey: Key.suppressedEpisodeID)
    }
}
