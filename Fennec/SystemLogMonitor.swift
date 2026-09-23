import CoreAudio
import Foundation
import OSLog

enum SystemLogMonitorError: LocalizedError {
    case storeUnavailable(underlying: String)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable(let underlying):
            return "Could not read the system log for Core Audio overload entries "
                + "(usually because this account is not an administrator). "
                + "Listener-based detection continues. \(underlying)"
        }
    }
}

/// Watches `coreaudiod`'s own overload messages in the unified log.
///
/// This is the second detection path, and it exists because the first one has
/// a blind spot the size of the actual field failure: the
/// `kAudioDeviceProcessorOverload` notification fires in the process whose IO
/// cycle overloaded, and when that process is someone else (a different app,
/// or coreaudiod's IO thread serving a misbehaving client), Fennec's listener
/// hears nothing while the speakers audibly crackle. `coreaudiod` logs every
/// overload it detects, for every client, and the log store is readable by
/// admin users without privileges. See `OverloadLogSchedule` for why queries
/// are gated on the output device actually running IO.
///
/// Not real-time code: everything here runs on one utility-QoS serial queue.
final class SystemLogMonitor: @unchecked Sendable {
    /// Delivers each overload event's true log timestamp, oldest first, so
    /// detection window math runs on when the fault happened rather than on
    /// when the poll noticed it.
    typealias OverloadHandler = @Sendable (_ eventDates: [Date]) -> Void
    /// Clean IO stop and start timestamps from the same query: the playback
    /// stall signature, delivered raw for the advisor and the graph to judge.
    typealias IOStateHandler = @Sendable (_ stopDates: [Date], _ startDates: [Date]) -> Void
    /// One per tick while audio is actually playing: the graph's activity
    /// trace. Silence delivers nothing; a gap in the trace is the gap.
    typealias ActivityHandler = @Sendable (_ date: Date) -> Void
    /// A successful query, including an empty one, and the interval it covered.
    typealias CoverageHandler = @Sendable (_ from: Date, _ through: Date, _ eventDates: [Date]) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    /// One overload event writes exactly one line containing this marker
    /// (`HALS_OverloadMessage.cpp`, default level), plus a variable number of
    /// error-level cause lines matched by `auxiliaryNeedle` below.
    private static let markerNeedle = "Audio IO Overload thread"
    private static let auxiliaryNeedle = "HALS_OverloadMessage"
    /// Clean IO teardown and bring-up (`HALS_IOEngine2`). One stop and one
    /// start per playback stall; also emitted by ordinary pause/play, which
    /// is why `StallAdvisor` demands a starved machine before saying anything.
    private static let ioStopNeedle = "StopIO: stopping IO"
    private static let ioStartNeedle = "StartIO: starting IO"

    private let queue = DispatchQueue(
        label: "com.ludicrousdesigns.Fennec.system-log-monitor",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var hasFailed = false
    /// Newest log entry already counted; the next query reads strictly after.
    private var lastProcessedDate = Date()
    private var lastQueryDate: Date?
    private var lastOverloadSeen: Date?
    private var lastRunningSeen: Date?

    private var currentTickInterval: TimeInterval = OverloadLogSchedule.tick

    /// Cached HAL addressing for the per-tick gate. The gate used to resolve
    /// the default device, check the property exists, and read it (three XPC
    /// round trips measured at 1.2 ms) every single tick, which at the 1 s
    /// playing cadence is ~0.12% of a core all day for three answers that
    /// only change when the output device does. Cached, the steady tick is
    /// one ~0.15 ms read. The cache re-resolves on a slow cadence, on any
    /// read error, and on `noteOutputDeviceMayHaveChanged()` from the
    /// listener path, so a device switch is picked up within a drain cycle
    /// rather than waiting out the cadence.
    private var cachedOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var cachedDeviceAnswersRunning = false
    private var ticksUntilDeviceRefresh = 0
    private static let deviceRefreshTicks = 10

    var onOverloads: OverloadHandler?
    var onIOStateChanges: IOStateHandler?
    var onActivitySample: ActivityHandler?
    var onSuccessfulCoverage: CoverageHandler?
    var onError: ErrorHandler?

    func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true
            hasFailed = false
            lastProcessedDate = Date()
            lastQueryDate = nil
            lastOverloadSeen = nil
            lastRunningSeen = nil

            let timer = DispatchSource.makeTimerSource(queue: queue)
            currentTickInterval = OverloadLogSchedule.tick
            scheduleLocked(timer, interval: currentTickInterval)
            timer.setEventHandler { [weak self] in
                self?.tickLocked()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            isRunning = false
        }
    }

    /// Runs the next due query immediately rather than waiting out the
    /// current interval, for the moment the popover opens and the graph
    /// wants the freshest window it can get.
    func pollNow() {
        queue.async { [weak self] in
            guard let self, self.isRunning, !self.hasFailed else { return }
            self.lastQueryDate = nil
            self.tickLocked()
        }
    }

    private func scheduleLocked(_ timer: DispatchSourceTimer, interval: TimeInterval) {
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            // Nothing here is timing-critical to better than a tick, so
            // let the kernel coalesce these wake-ups aggressively.
            leeway: .milliseconds(Int(interval * 500))
        )
    }

    private func tickLocked() {
        guard isRunning, !hasFailed else { return }
        let now = Date()
        let running = defaultOutputIsRunningSomewhere()
        if running {
            lastRunningSeen = now
            onActivitySample?(now)
        }

        // 1 s ticks while audio plays make playback gaps visible on the
        // graph; silence relaxes back to the slow tick.
        let recentlyRunning = lastRunningSeen.map {
            now.timeIntervalSince($0) < OverloadLogSchedule.runningGrace
        } ?? false
        let desiredTick = OverloadLogSchedule.tickInterval(recentlyRunning: recentlyRunning)
        if desiredTick != currentTickInterval, let timer {
            currentTickInterval = desiredTick
            scheduleLocked(timer, interval: desiredTick)
        }

        guard OverloadLogSchedule.queryIsDue(
            deviceRunning: running,
            now: now,
            lastQuery: lastQueryDate,
            lastOverloadSeen: lastOverloadSeen,
            lastRunningSeen: lastRunningSeen
        ) else { return }
        lastQueryDate = now
        queryLocked()
    }

    private func queryLocked() {
        let store: OSLogStore
        do {
            store = try OSLogStore(scope: .system)
        } catch {
            // Almost always a permanent condition: the account is not an
            // administrator. Say so once and stand down rather than retrying
            // a denied open four times a minute forever.
            hasFailed = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            onError?(SystemLogMonitorError.storeUnavailable(underlying: error.localizedDescription))
            return
        }

        var markers: [Date] = []
        var auxiliary: [Date] = []
        var ioStops: [Date] = []
        var ioStarts: [Date] = []
        let coveredFrom = lastProcessedDate
        var newest = lastProcessedDate
        let queryStart = Date()
        do {
            let position = store.position(date: lastProcessedDate)
            let predicate = NSPredicate(
                format: "process == 'coreaudiod' AND (composedMessage CONTAINS %@ OR composedMessage CONTAINS %@ "
                    + "OR composedMessage CONTAINS %@ OR composedMessage CONTAINS %@)",
                Self.markerNeedle, Self.auxiliaryNeedle, Self.ioStopNeedle, Self.ioStartNeedle
            )
            for entry in try store.getEntries(at: position, matching: predicate) {
                guard let log = entry as? OSLogEntryLog, log.date > lastProcessedDate else { continue }
                let message = log.composedMessage
                if message.contains(Self.markerNeedle) {
                    markers.append(log.date)
                } else if message.contains(Self.ioStopNeedle) {
                    ioStops.append(log.date)
                } else if message.contains(Self.ioStartNeedle) {
                    ioStarts.append(log.date)
                } else {
                    auxiliary.append(log.date)
                }
                if log.date > newest { newest = log.date }
            }
        } catch {
            // A failed enumeration with an open store is worth retrying on
            // the next due query; it is not the permission case.
            return
        }
        // Advance past everything this query enumerated, not just to the
        // newest *matching* entry. `newest` alone was a real CPU leak: on a
        // healthy machine nothing matches, the cursor never moved, and every
        // poll re-enumerated an ever-growing window, so CPU per poll grew
        // linearly for as long as playback continued without a stop. The lag
        // margin covers logd's flush delay so an entry that lands in the
        // store late cannot be skipped; no matching entry can sit between
        // `newest` and the margin, because matching entries advanced
        // `newest` past themselves above.
        lastProcessedDate = max(newest, queryStart.addingTimeInterval(-10))
        guard isRunning else { return }

        let events = OverloadLogGrouper.eventDates(markers: markers, auxiliary: auxiliary)
        onSuccessfulCoverage?(coveredFrom, lastProcessedDate, events)

        if !ioStops.isEmpty || !ioStarts.isEmpty {
            onIOStateChanges?(ioStops.sorted(), ioStarts.sorted())
        }

        guard let newestEvent = events.last else { return }
        lastOverloadSeen = newestEvent
        onOverloads?(events)
    }

    /// The listener path saw the default output change; drop the cached
    /// device so the next tick reads the right one instead of waiting out
    /// the refresh cadence, which would paint a false gap in the activity
    /// ribbon for those seconds.
    func noteOutputDeviceMayHaveChanged() {
        queue.async { [weak self] in
            self?.ticksUntilDeviceRefresh = 0
        }
    }

    /// The cheap gate in front of the expensive query: whether the default
    /// output device is running IO for any process at all. No IO cycles, no
    /// overloads, nothing audible, no query. One cached ~0.15 ms property
    /// read on the steady path; see the cache fields for why.
    private func defaultOutputIsRunningSomewhere() -> Bool {
        if ticksUntilDeviceRefresh <= 0
            || cachedOutputDeviceID == AudioObjectID(kAudioObjectUnknown) {
            refreshCachedDeviceLocked()
        }
        ticksUntilDeviceRefresh -= 1

        guard cachedOutputDeviceID != AudioObjectID(kAudioObjectUnknown) else { return false }
        // A device that cannot answer should not silence detection.
        guard cachedDeviceAnswersRunning else { return true }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(cachedOutputDeviceID, &address, 0, nil, &size, &running)
        guard status == noErr else {
            // The cached device likely went away; re-resolve on the next
            // tick, and do not let a stale handle silence detection now.
            ticksUntilDeviceRefresh = 0
            return true
        }
        return running != 0
    }

    private func refreshCachedDeviceLocked() {
        ticksUntilDeviceRefresh = Self.deviceRefreshTicks
        guard let deviceID = try? CoreAudioReader.defaultOutputDeviceID(),
              deviceID != kAudioObjectUnknown else {
            cachedOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
            cachedDeviceAnswersRunning = false
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        cachedOutputDeviceID = deviceID
        cachedDeviceAnswersRunning = AudioObjectHasProperty(deviceID, &address)
    }
}
