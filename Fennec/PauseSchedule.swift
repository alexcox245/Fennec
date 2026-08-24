import Foundation

/// "Not right now."
///
/// Fennec's safety checks already refuse to restart Core Audio during a call
/// or a recording, but they can only see what Core Audio tells them. A person
/// tracking a guitar take, running a listening test, or demoing to a room
/// knows things Core Audio does not.
///
/// Pause is the manual override, and the reason it exists is retention: the
/// alternative to a two-hour pause is a professional turning automatic repair
/// off permanently after one mistimed restart. Every duration except the last
/// expires on its own, and the menu-bar mark changes while it is on, so it can
/// never be quietly left running.
enum PauseSchedule {
    enum Option: String, CaseIterable, Identifiable, Sendable {
        case fifteenMinutes
        case oneHour
        case fourHours
        case untilResumed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fifteenMinutes: return "For 15 Minutes"
            case .oneHour: return "For 1 Hour"
            case .fourHours: return "For 4 Hours"
            case .untilResumed: return "Until I Turn It Back On"
            }
        }

        /// `nil` means indefinite — it only ends when the user says so.
        var duration: TimeInterval? {
            switch self {
            case .fifteenMinutes: return 15 * 60
            case .oneHour: return 60 * 60
            case .fourHours: return 4 * 60 * 60
            case .untilResumed: return nil
            }
        }
    }

    /// The instant a pause ends, or `nil` for indefinite.
    static func expiry(for option: Option, from now: Date = Date()) -> Date? {
        option.duration.map { now.addingTimeInterval($0) }
    }
}

/// The persisted pause, resolved against a clock.
///
/// Stored as two plain values so a stale `pausedUntil` in `UserDefaults` can
/// never outlive its meaning: an expired timestamp simply resolves to
/// `.running` on the next read, including after a reboot.
struct PauseState: Equatable, Sendable {
    var isIndefinite: Bool
    var until: Date?

    static let running = PauseState(isIndefinite: false, until: nil)

    static func indefinite() -> PauseState {
        PauseState(isIndefinite: true, until: nil)
    }

    static func until(_ date: Date) -> PauseState {
        PauseState(isIndefinite: false, until: date)
    }

    static func make(for option: PauseSchedule.Option, from now: Date = Date()) -> PauseState {
        guard let expiry = PauseSchedule.expiry(for: option, from: now) else { return .indefinite() }
        return .until(expiry)
    }

    func isPaused(at now: Date = Date()) -> Bool {
        if isIndefinite { return true }
        guard let until else { return false }
        return until > now
    }

    /// Seconds left, or `nil` when running or paused indefinitely.
    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard !isIndefinite, let until, until > now else { return nil }
        return until.timeIntervalSince(now)
    }

    /// Drops an expired expiry so callers can persist a clean value.
    func resolved(at now: Date = Date()) -> PauseState {
        isPaused(at: now) ? self : .running
    }

    /// Menu-bar and popover status text. Deliberately states the deadline
    /// rather than a countdown — nothing in this app ticks for attention.
    func statusText(at now: Date = Date()) -> String? {
        guard isPaused(at: now) else { return nil }
        if isIndefinite { return "Paused" }
        guard let remaining = remaining(at: now) else { return "Paused" }

        let minutes = Int((remaining / 60).rounded(.up))
        if minutes <= 1 { return "Paused · resumes in under a minute" }
        if minutes < 60 { return "Paused · resumes in \(minutes) min" }

        let hours = Double(minutes) / 60
        let rendered = hours.rounded() == hours
            ? String(format: "%.0f", hours)
            : String(format: "%.1f", hours)
        return "Paused · resumes in \(rendered) h"
    }
}
