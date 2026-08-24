import Foundation

/// Every user-facing sentence Fennec says about a repair.
///
/// It lives in one place for two reasons. The obvious one: the notification,
/// the menu receipt, and the activity list must not drift apart. The real
/// one: this copy is the product. Fennec's whole claim is that it names the
/// mechanism instead of shrugging — "Core Audio missed its deadline twice in
/// 5.8 s", never "something went wrong". Keeping the strings pure keeps them
/// under test.
enum RepairCopy {

    // MARK: Numbers

    /// Durations the way an engineer reads them: precise when small, coarse
    /// when large. `0.84 s`, `1.2 s`, `12 s`.
    static func duration(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value < 1 { return String(format: "%.2f s", value) }
        if value < 10 { return String(format: "%.1f s", value) }
        return String(format: "%.0f s", value)
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    // MARK: What happened

    /// The cause clause: what Fennec saw, on which device. Always a complete
    /// sentence so it can lead a notification body.
    static func cause(for record: RepairRecord) -> String {
        let device = record.deviceName.isEmpty ? "the output device" : record.deviceName

        switch record.signal {
        case .ioStoppedAbnormally:
            return "Core Audio I/O stopped abnormally on \(device)."

        case .processorOverload:
            let signals = count(record.signalCount, "crackle signal", "crackle signals")
            if record.signalCount <= 1 {
                return "One crackle signal on \(device)."
            }
            if record.elapsedSeconds < 0.5 {
                return "\(signals) back to back on \(device)."
            }
            return "\(signals) in \(duration(record.elapsedSeconds)) on \(device)."

        case nil:
            return "You asked for a reset on \(device)."
        }
    }

    /// The result clause: what Fennec did about it.
    static func outcome(for record: RepairRecord) -> String {
        record.succeeded
            ? "Core Audio restarted in \(duration(record.durationSeconds))."
            : record.message
    }

    // MARK: Notifications

    static func notificationTitle(for record: RepairRecord) -> String {
        guard record.succeeded else { return "Fennec could not repair audio" }
        return record.trigger == .automatic ? "Fennec fixed your audio" : "Core Audio restarted"
    }

    static func notificationBody(for record: RepairRecord) -> String {
        guard record.succeeded else {
            return "\(cause(for: record)) \(record.message)"
        }
        if record.trigger == .manual {
            return outcome(for: record)
        }
        return "\(cause(for: record)) \(outcome(for: record))"
    }

    // MARK: The menu receipt

    /// Short enough for a 384 pt popover row.
    ///
    /// The wording tracks the *outcome*, not the call's return value. The
    /// instant a repair finishes, the only established fact is that a new
    /// Core Audio process exists; "fixed" is a claim about the next minute.
    static func receiptHeadline(for record: RepairRecord) -> String {
        switch record.outcome {
        case .failed:
            return "Repair failed"
        case .pending:
            return "Restarted in \(duration(record.durationSeconds)) · watching"
        case .returned:
            return "Restarted, but the fault came back"
        case .held:
            return record.trigger == .automatic
                ? "Caught and fixed in \(duration(record.durationSeconds))"
                : "Restarted in \(duration(record.durationSeconds))"
        }
    }

    static func receiptDetail(for record: RepairRecord) -> String {
        switch record.outcome {
        case .failed:
            return record.message
        case .returned:
            return "\(cause(for: record)) Restarting Core Audio did not clear it."
        case .pending, .held:
            return cause(for: record)
        }
    }

    /// The banner that replaces "Fennec fixed your audio" when it turns out
    /// not to have. Same notification identifier, so it corrects itself in
    /// place rather than stacking a contradiction underneath.
    static func faultReturnedTitle(for record: RepairRecord) -> String {
        "Core Audio is still crackling"
    }

    static func faultReturnedBody(for record: RepairRecord) -> String {
        "The fault came back after Fennec restarted \(record.deviceName.isEmpty ? "the output device" : record.deviceName). "
            + "That usually means the restart is not the cure."
    }

    // MARK: Running totals

    /// The line under the counter. Deadpan, and true even at zero.
    static func summaryLine(for summary: RepairSummary, now: Date = Date()) -> String {
        guard summary.held > 0 else {
            return "No repairs yet. Fennec is listening."
        }
        let repairs = count(summary.held, "repair", "repairs")
        guard let first = summary.firstDate else { return repairs }

        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let sinceDay = Calendar.current.isDate(first, inSameDayAs: now)
            ? "today"
            : "since \(formatter.string(from: first))"
        return "\(repairs) \(sinceDay)."
    }

    /// The one number that makes the value obvious at a glance.
    static func headlineNumber(for summary: RepairSummary) -> String {
        "\(summary.held)"
    }
}
