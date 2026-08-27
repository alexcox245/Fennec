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
/// property read that costs ~0.15 ms on a cached device handle: whether the
/// output device is running IO for anyone at all. No audio moving means no
/// IO cycles, no overloads, and nothing audible to protect — so no query.
enum OverloadLogSchedule {
    /// The cheap wake-up: read `kAudioDevicePropertyDeviceIsRunningSomewhere`
    /// and decide whether the expensive query is due.
    static let tick: TimeInterval = 5

    /// The tick while audio is (or was just) playing. Each tick is a ~0.15 ms
    /// cached property read, and it doubles as the graph's activity trace — one
    /// sample per second is what makes a playback gap visible as a gap.
    /// Silence relaxes back to the 5 s tick, per the stillness rule.
    static let activityTick: TimeInterval = 1

    static func tickInterval(recentlyRunning: Bool) -> TimeInterval {
        recentlyRunning ? activityTick : tick
    }

    /// Query interval while audio is playing and the log has been quiet.
    ///
    /// The budget arithmetic, measured on this machine: one query costs
    /// roughly a second of CPU (store open ~0.7 s + enumeration), so the
    /// steady-state cost while music plays is queryCost / watch. At 120 s
    /// that is under one percent of a core, which is the whole app's CPU
    /// budget. The price is latency: a fault that starts mid-playback is
    /// noticed within about two minutes — acceptable, because the fault
    /// this exists for persists until repaired.
    static let watch: TimeInterval = 120

    /// Query interval once overload entries have been seen recently. The
    /// cadence only bounds *reporting* latency: detection windows run on the
    /// events' own log timestamps, so a poll interval wider than a window
    /// cannot starve it of a second signal. ~3% of a core, only while a
    /// fault is actually in progress.
    static let fault: TimeInterval = 30

    /// How long after the last overload entry the fast interval applies.
    static let faultLingers: TimeInterval = 120

    /// How long after the device was last seen running IO the query keeps
    /// going anyway. A playback stall *is* the device stopping — gating
    /// purely on "running right now" would blind the monitor to the very
    /// stop/start churn it needs to see.
    static let runningGrace: TimeInterval = 180

    /// Log lines that belong to the same overload event land within a few
    /// milliseconds of each other; distinct events observed in the field are
    /// tens of milliseconds apart or more.
    static let mergeWindow: TimeInterval = 0.05

    static func queryInterval(deviceRunning: Bool, quietFor: TimeInterval) -> TimeInterval? {
        guard deviceRunning else { return nil }
        return quietFor < faultLingers ? fault : watch
    }

    /// Whether a query is due on this tick. `lastRunningSeen` extends the
    /// device-running gate through short silences (see `runningGrace`).
    static func queryIsDue(
        deviceRunning: Bool,
        now: Date,
        lastQuery: Date?,
        lastOverloadSeen: Date?,
        lastRunningSeen: Date? = nil
    ) -> Bool {
        let recentlyRunning = lastRunningSeen.map { now.timeIntervalSince($0) < runningGrace } ?? false
        let quietFor = lastOverloadSeen.map { now.timeIntervalSince($0) } ?? .infinity
        guard let interval = queryInterval(
            deviceRunning: deviceRunning || recentlyRunning,
            quietFor: quietFor
        ) else {
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
/// Turns per-second "the output device was running" samples into the merged
/// time segments the graph paints as its activity ribbon. A gap wider than
/// the merge window is a real gap — the moment the music cut out.
enum AudioActivitySegments {
    /// A shade over one sample interval, so adjacent samples fuse and a
    /// single missed sample does not fake a dropout.
    static let mergeWindow: TimeInterval = OverloadLogSchedule.activityTick * 1.6

    static func merged(
        sampleDates: [Date],
        mergeWithin: TimeInterval = mergeWindow
    ) -> [ClosedRange<Date>] {
        var segments: [ClosedRange<Date>] = []
        for date in sampleDates.sorted() {
            if let last = segments.last, date.timeIntervalSince(last.upperBound) <= mergeWithin {
                segments[segments.count - 1] = last.lowerBound...date
            } else {
                segments.append(date...date)
            }
        }
        return segments
    }
}

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
