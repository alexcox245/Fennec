import Foundation

/// How many banners Fennec is allowed to post, and how often.
///
/// The failure this exists to prevent is specific and was shipping: a Mac
/// under sustained load emits overload signals in bursts, and a Fennec that is
/// detecting but not repairing — auto-repair off, helper not enabled yet,
/// Bluetooth output, a live microphone — had nothing stopping it from posting
/// a sound-playing, two-button banner for every one of them. An app whose
/// whole position is desert stillness was, out of the box, the noisiest thing
/// on the machine.
///
/// So: detections are budgeted, repairs are not. A repair is rare by
/// construction — it is rate-limited by the cooldown, by the helper's own
/// 20-second floor, and by the fact that it only happens when something
/// actually broke. A detection Fennec declined to act on can happen every few
/// seconds for an hour.
struct NotificationBudget: Equatable, Sendable {
    /// Ten minutes. Long enough that a bad afternoon produces a handful of
    /// banners rather than a hundred; short enough that a genuinely new
    /// problem is not sat on for the rest of the day.
    static let defaultInterval: TimeInterval = 600

    let minimumInterval: TimeInterval
    private(set) var lastPostedAt: Date?
    /// Everything the budget swallowed since the last post. Surfaced in the
    /// next banner so suppression is never silent.
    private(set) var suppressedCount = 0

    init(minimumInterval: TimeInterval = NotificationBudget.defaultInterval, lastPostedAt: Date? = nil) {
        self.minimumInterval = max(0, minimumInterval)
        self.lastPostedAt = lastPostedAt
    }

    /// Records an attempt and reports whether it may be posted.
    mutating func allow(at now: Date = Date()) -> Bool {
        guard let lastPostedAt else {
            self.lastPostedAt = now
            suppressedCount = 0
            return true
        }
        guard now.timeIntervalSince(lastPostedAt) >= minimumInterval else {
            suppressedCount += 1
            return false
        }
        self.lastPostedAt = now
        return true
    }

    /// The count to mention in the banner that finally gets through, or `nil`
    /// when nothing was held back.
    func suppressedSinceLastPost() -> Int? {
        suppressedCount > 0 ? suppressedCount : nil
    }

    /// Called after a post has consumed the suppressed backlog.
    mutating func clearSuppressed() {
        suppressedCount = 0
    }

    /// Seconds until the next post would be allowed, or `nil` if one is
    /// allowed now.
    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard let lastPostedAt else { return nil }
        let elapsed = now.timeIntervalSince(lastPostedAt)
        return elapsed >= minimumInterval ? nil : minimumInterval - elapsed
    }

    /// A repair happened, so the user is up to date. The next detection that
    /// Fennec declines to act on is news again.
    mutating func reset() {
        lastPostedAt = nil
        suppressedCount = 0
    }
}
