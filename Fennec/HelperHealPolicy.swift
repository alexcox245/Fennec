import Foundation

/// Whether Fennec may rebuild the helper's registration on its own, right now.
///
/// The state this exists for is the one the UI calls "Enabled, not
/// responding": macOS still holds a registration for the daemon — the user's
/// approval is on record — but launchd cannot produce a helper that answers.
/// A registration binds to the bundle path and signature that made it, so
/// replacing the build or moving the app leaves launchd pointing at a bundle
/// that is gone. Observed on a live machine as 9,736 spawn attempts and then
/// "Could not find and/or execute program specified by service".
///
/// Re-registering from the running bundle rewrites that record without a
/// password, so the fix is automatable. This type decides *when*, and it is
/// deliberately the only place that decides:
///
/// - Never when macOS does not report the daemon enabled. `.requiresApproval`
///   and `.notRegistered` are the user's call, and touching the registration
///   in those states would turn their decision into ours.
/// - Never when the helper is answering. There is nothing to heal.
/// - Automatically, at most once per `minimumInterval`. If a rebuild did not
///   bring the helper back, rebuilding again in a loop will not either — it
///   just flaps the Background Task Management record.
/// - Always for a user-initiated attempt. The interval exists to stop Fennec
///   from flapping, not to make a button do nothing.
struct HelperHealPolicy: Equatable, Sendable {
    /// Ten minutes, matching `NotificationBudget`: long enough that a
    /// registration that genuinely cannot be rebuilt is not thrashed all
    /// afternoon, short enough that the next detection after a failed attempt
    /// gets a fresh try soon.
    static let defaultInterval: TimeInterval = 600

    let minimumInterval: TimeInterval
    private(set) var lastAttempt: Date?

    init(minimumInterval: TimeInterval = HelperHealPolicy.defaultInterval, lastAttempt: Date? = nil) {
        self.minimumInterval = max(0, minimumInterval)
        self.lastAttempt = lastAttempt
    }

    /// Records the attempt when it grants one, so a caller that asks is
    /// expected to follow through.
    mutating func shouldAttempt(
        enabled: Bool,
        reachable: Bool,
        userInitiated: Bool,
        now: Date = Date()
    ) -> Bool {
        guard enabled, !reachable else { return false }
        if !userInitiated,
           let lastAttempt,
           now.timeIntervalSince(lastAttempt) < minimumInterval {
            return false
        }
        lastAttempt = now
        return true
    }
}
