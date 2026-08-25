import Foundation

/// When to run the unified-log query, and how to turn matched log lines into
/// a count of overload *events*.
///
/// Why this component exists at all: `kAudioDeviceProcessorOverload` is
/// delivered by the HAL inside the process whose IO cycle missed its
/// deadline. When the overloading client is some other process — verified on
/// a live faulting machine, where an iOS Simulator daemon's silent audio
/// context overloaded coreaudiod's IO thread several times a second for
/// hours — Fennec's property listener never fires, and neither does a
/// healthy sibling IOProc show any timing artifact. The one place the fault
/// is observable from outside the faulting process is `coreaudiod`'s own
/// `HALS_OverloadMessage` entries in the unified log.
///
/// Reading the log store is not free: opening the store plus enumerating a
/// few seconds of entries costs on the order of a second of background CPU
/// per query (measured). A product whose proudest claim is stillness cannot
/// spend that four times a minute forever, so the schedule is gated on a
/// property read that costs ~40 µs: whether the output device is running IO
/// for anyone at all. No audio moving means no IO cycles, no overloads, and
/// nothing audible to protect — so no query.
enum OverloadLogSchedule {
    /// The cheap wake-up: read `kAudioDevicePropertyDeviceIsRunningSomewhere`
    /// and decide whether the expensive query is due.
    static let tick: TimeInterval = 5

    /// Query interval while audio is playing and the log has been quiet.
    /// This is the worst-case added latency between an inaudible machine
    /// and Fennec noticing, and it is deliberately the slowest number here:
    /// the fault this exists for persists until repaired.
    static let watch: TimeInterval = 30

    /// Query interval once overload entries have been seen recently. The
    /// cadence only bounds *reporting* latency: detection windows run on the
    /// events' own log timestamps, so a poll interval wider than a window
    /// cannot starve it of a second signal.
    static let fault: TimeInterval = 10

    /// How long after the last overload entry the fast interval applies.
    static let faultLingers: TimeInterval = 300

    /// Log lines that belong to the same overload event land within a few
    /// milliseconds of each other; distinct events observed in the field are
    /// tens of milliseconds apart or more.
    static let mergeWindow: TimeInterval = 0.05

    static func queryInterval(deviceRunning: Bool, quietFor: TimeInterval) -> TimeInterval? {
        guard deviceRunning else { return nil }
        return quietFor < faultLingers ? fault : watch
    }

    /// Whether a query is due on this tick.
    static func queryIsDue(
        deviceRunning: Bool,
        now: Date,
        lastQuery: Date?,
        lastOverloadSeen: Date?
    ) -> Bool {
        let quietFor = lastOverloadSeen.map { now.timeIntervalSince($0) } ?? .infinity
        guard let interval = queryInterval(deviceRunning: deviceRunning, quietFor: quietFor) else {
            return false
        }
        guard let lastQuery else { return true }
        return now.timeIntervalSince(lastQuery) >= interval
    }
}

/// Turns matched log lines into overload event dates.
///
/// One overload produces a small burst of lines: exactly one
/// "Audio IO Overload thread" marker plus a variable number of cause lines.
/// Counting the marker is exact. If a macOS update ever rewords the marker
/// but not the rest, the fallback clusters whatever cause lines still match
/// into bursts, so the signal degrades to approximate instead of to zero.
enum OverloadLogGrouper {
    static func eventDates(
        markers: [Date],
        auxiliary: [Date],
        mergeWindow: TimeInterval = OverloadLogSchedule.mergeWindow
    ) -> [Date] {
        if !markers.isEmpty {
            return markers.sorted()
        }
        var events: [Date] = []
        for date in auxiliary.sorted() {
            if let last = events.last, date.timeIntervalSince(last) < mergeWindow {
                continue
            }
            events.append(date)
        }
        return events
    }
}
