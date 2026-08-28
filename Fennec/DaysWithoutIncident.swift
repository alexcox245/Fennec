import Foundation

/// The sign on the wall of the workshop.
///
/// A background utility that works is indistinguishable from one that does
/// nothing, and the honest fix for that is not a dashboard; it is a single
/// number that means something. This is the industrial safety sign, kept the
/// way a real one is kept: it counts up while nothing goes wrong, and on the
/// day something does it reads **0**, with no softening and no apology.
///
/// It changes only at midnight, because a sign that ticks is a timer, and a
/// timer is a thing you watch. Nobody should watch this.
struct DaysWithoutIncident: Equatable, Sendable {
    /// Whole calendar days since the last repair Fennec had to perform.
    let days: Int
    /// The incident being counted from, if there has been one.
    let lastIncident: Date?
    /// True when Fennec has simply never had to step in.
    let isCleanRecord: Bool

    /// The line under the number. Deadpan, specific, and true at zero.
    var caption: String {
        if let lastIncident {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            let day = formatter.string(from: lastIncident)
            return days == 0 ? "Last repair today." : "Last repair \(day)."
        }
        if isCleanRecord && days == 0 {
            return "Fennec started listening today."
        }
        return "Fennec has never had to step in."
    }

    /// Read by VoiceOver as a sentence rather than a bare numeral.
    var accessibilityLabel: String {
        "\(days) \(days == 1 ? "day" : "days") without incident. \(caption)"
    }

    /// An incident is a repair Fennec actually had to perform: one that held,
    /// one that did not, or one that failed. A manual repair counts too: the
    /// user only pressed the button because something was wrong.
    static func make(
        records: [RepairRecord],
        listeningSince: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DaysWithoutIncident {
        let today = calendar.startOfDay(for: now)

        // The rehearsal first run asks for is not an incident: nothing was
        // wrong, and this type's own justification for counting manual repairs
        // ("the user only pressed the button because something was wrong")
        // is precisely untrue of it.
        let records = records.filter { $0.trigger != .rehearsal }

        guard let lastIncident = records.map(\.date).max() else {
            let start = calendar.startOfDay(for: min(listeningSince, now))
            return DaysWithoutIncident(
                days: max(0, calendar.dateComponents([.day], from: start, to: today).day ?? 0),
                lastIncident: nil,
                isCleanRecord: true
            )
        }

        let incidentDay = calendar.startOfDay(for: min(lastIncident, now))
        return DaysWithoutIncident(
            days: max(0, calendar.dateComponents([.day], from: incidentDay, to: today).day ?? 0),
            lastIncident: lastIncident,
            isCleanRecord: false
        )
    }
}
