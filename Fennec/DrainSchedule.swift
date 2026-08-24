import Foundation

/// How often to drain the real-time counters.
///
/// 99.99% of Fennec's life is idle, and it used to wake four times a second
/// to confirm that — forever, whether or not a signal had ever arrived. For a
/// product whose proudest claim is stillness, being the loudest thing in
/// Activity Monitor is a bad look and a fair criticism.
///
/// Backing off is safe because the Core Audio property listener runs on Core
/// Audio's side regardless and the counters are atomic: a longer drain
/// interval delays *noticing* a signal, it never loses one. And the first
/// non-empty drain snaps straight back to the fast tier, so the second signal
/// of a Balanced detection is still timed at 250 ms resolution — which is the
/// one place the resolution actually matters.
enum DrainSchedule {
    /// Signals are arriving, or arrived recently.
    static let active: TimeInterval = 0.25
    /// Quiet for a minute.
    static let idle: TimeInterval = 1.0
    /// Quiet for five.
    static let deepIdle: TimeInterval = 2.0

    static let idleAfter: TimeInterval = 60
    static let deepIdleAfter: TimeInterval = 300

    static func interval(quietFor seconds: TimeInterval) -> TimeInterval {
        if seconds >= deepIdleAfter { return deepIdle }
        if seconds >= idleAfter { return idle }
        return active
    }

    /// Generous leeway while idle lets the kernel coalesce Fennec's wake-ups
    /// with everything else that has to happen anyway. At the active tier it
    /// stays tight, because that is when the timing is load-bearing.
    static func leeway(for interval: TimeInterval) -> TimeInterval {
        interval <= active ? 0.05 : interval * 0.5
    }
}
