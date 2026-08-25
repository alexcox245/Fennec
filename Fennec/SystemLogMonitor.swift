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
/// cycle overloaded, and when that process is someone else — a different app,
/// or coreaudiod's IO thread serving a misbehaving client — Fennec's listener
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
    typealias ErrorHandler = @Sendable (Error) -> Void

    /// One overload event writes exactly one line containing this marker
    /// (`HALS_OverloadMessage.cpp`, default level), plus a variable number of
    /// error-level cause lines matched by `auxiliaryNeedle` below.
    private static let markerNeedle = "Audio IO Overload thread"
    private static let auxiliaryNeedle = "HALS_OverloadMessage"

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

    var onOverloads: OverloadHandler?
    var onError: ErrorHandler?

    func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true
            hasFailed = false
            lastProcessedDate = Date()
            lastQueryDate = nil
            lastOverloadSeen = nil

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + OverloadLogSchedule.tick,
                repeating: OverloadLogSchedule.tick,
                // Nothing here is timing-critical to better than a tick, so
                // let the kernel coalesce these wake-ups aggressively.
                leeway: .milliseconds(Int(OverloadLogSchedule.tick * 500))
            )
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

    private func tickLocked() {
        guard isRunning, !hasFailed else { return }
        let now = Date()
        guard OverloadLogSchedule.queryIsDue(
            deviceRunning: defaultOutputIsRunningSomewhere(),
            now: now,
            lastQuery: lastQueryDate,
            lastOverloadSeen: lastOverloadSeen
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
        var newest = lastProcessedDate
        do {
            let position = store.position(date: lastProcessedDate)
            let predicate = NSPredicate(
                format: "process == 'coreaudiod' AND (composedMessage CONTAINS %@ OR composedMessage CONTAINS %@)",
                Self.markerNeedle, Self.auxiliaryNeedle
            )
            for entry in try store.getEntries(at: position, matching: predicate) {
                guard let log = entry as? OSLogEntryLog, log.date > lastProcessedDate else { continue }
                if log.composedMessage.contains(Self.markerNeedle) {
                    markers.append(log.date)
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
        lastProcessedDate = newest

        let events = OverloadLogGrouper.eventDates(markers: markers, auxiliary: auxiliary)
        guard let newestEvent = events.last, isRunning else { return }
        lastOverloadSeen = newestEvent
        onOverloads?(events)
    }

    /// The ~40 µs gate in front of the ~1 s query: whether the default output
    /// device is running IO for any process at all. No IO cycles, no
    /// overloads, nothing audible — no query.
    private func defaultOutputIsRunningSomewhere() -> Bool {
        guard let deviceID = try? CoreAudioReader.defaultOutputDeviceID(),
              deviceID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            // A device that cannot answer should not silence detection.
            return true
        }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running)
        guard status == noErr else { return true }
        return running != 0
    }
}
