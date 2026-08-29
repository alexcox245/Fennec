import Foundation

/// What became of a repair, once there was time to find out.
///
/// The only thing Fennec knows the instant a repair returns is that a new
/// `coreaudiod` process exists. Whether the *fault* is gone is a different
/// question, and it takes a minute of quiet to answer.
enum RepairOutcome: String, Codable, Sendable {
    /// Restarted; still inside the verification window.
    case pending
    /// The verification window closed with no further signals. It worked.
    case held
    /// The fault came back before the window closed. It did not.
    case returned
    /// The restart itself failed.
    case failed

    var isVerified: Bool { self == .held }

    /// The one place that decides how an outcome looks.
    ///
    /// `succeeded` is fixed at repair time; `outcome` is the axis that later
    /// becomes `.held` or `.returned`. Keying the receipt's accent off
    /// `succeeded` produced a gold seal directly above the headline
    /// "Restarted, but the fault came back": one card asserting two opposite
    /// things, on the machine where the truth matters most.
    var symbolName: String {
        switch self {
        case .held: return "checkmark.seal.fill"
        case .pending: return "clock"
        case .returned: return "arrow.uturn.backward.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// When to stop trying.
///
/// On a Mac where the restart is not the cure (a failing cable, a marginal
/// interface, a buffer size the machine cannot meet), Fennec's loop is:
/// detect, restart, claim success, wait out the cooldown, detect again.
/// Forever. Every 45 seconds, silencing all audio each time. That is the
/// single worst thing this product can do, and it is the *default*
/// configuration doing exactly what it was told.
///
/// So three restarts that did not hold means the restart is not the answer.
/// Fennec stands down for an hour and says the real numbers instead of
/// trying a fourth time.
enum RepairGovernor {
    /// How long the machine must stay quiet before a repair counts as held.
    /// Long enough to outlast the graph settling; short enough that a user
    /// watching the popover is not left staring at "pending".
    static let verificationWindow: TimeInterval = 60

    /// Repairs that did not hold, inside `standDownWindow`, before giving up.
    static let attemptsBeforeStandDown = 3

    /// The window those attempts have to fall inside to count as a pattern
    /// rather than a bad afternoon.
    static let standDownWindow: TimeInterval = 20 * 60

    static let standDownDuration: TimeInterval = 60 * 60

    struct StandDown: Equatable, Sendable {
        let until: Date
        let attempts: Int
        /// Span from the first counted attempt to the last.
        let elapsedSeconds: TimeInterval
        let deviceName: String

        /// Deadpan, specific, and it names the possibility the user needs to
        /// consider: repairing is not what fixes this.
        ///
        /// No timing here (T-043). "3 repairs in 12 minutes" told the user
        /// how fast Fennec gave up, which is not the point; that it gave up,
        /// and why, is.
        var reason: String {
            return "\(attempts) repairs on \(deviceName) did not hold. "
                + "Repairing is not fixing this, so Fennec has stood down for an hour."
        }

        func remaining(at now: Date) -> TimeInterval? {
            until > now ? until.timeIntervalSince(now) : nil
        }

        func isActive(at now: Date) -> Bool { until > now }
    }

    /// Whether Fennec should refuse to repair right now, given what happened.
    ///
    /// `records` is newest-first, as `RepairHistoryStore` keeps it.
    static func standDown(records: [RepairRecord], now: Date = Date()) -> StandDown? {
        let cutoff = now.addingTimeInterval(-standDownWindow)
        // Only automatic repairs count. A person pressing the button three
        // times has decided three times, and does not need to be overruled.
        let unhelpful = records.filter { record in
            record.date >= cutoff
                && record.trigger == .automatic
                && (record.outcome == .returned || record.outcome == .failed)
        }

        guard unhelpful.count >= attemptsBeforeStandDown else { return nil }
        guard let newest = unhelpful.map(\.date).max(),
              let oldest = unhelpful.map(\.date).min() else { return nil }

        let until = newest.addingTimeInterval(standDownDuration)
        guard until > now else { return nil }

        return StandDown(
            until: until,
            attempts: unhelpful.count,
            elapsedSeconds: newest.timeIntervalSince(oldest),
            deviceName: unhelpful.first?.deviceName ?? "the output device"
        )
    }

    /// The deadline by which a repair must have stayed quiet.
    static func verificationDeadline(after date: Date) -> Date {
        date.addingTimeInterval(verificationWindow)
    }
}
