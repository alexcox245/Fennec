import CoreAudio
import Foundation

enum CoreAudioMonitorError: LocalizedError {
    case allocationFailed
    case listenerFailed(selector: AudioObjectPropertySelector, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .allocationFailed:
            return "Could not allocate the real-time Core Audio signal counters."
        case .listenerFailed(let selector, let status):
            return "Could not install Core Audio listener \(fourCC(selector)); OSStatus \(status)."
        }
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

final class CoreAudioMonitor: @unchecked Sendable {
    typealias BatchHandler = @Sendable (AudioSignalBatch) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private struct ListenerRegistration: Equatable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: AudioObjectPropertyElement
    }

    private let controlQueue = DispatchQueue(label: "com.ludicrousdesigns.Fennec.coreaudio-monitor")
    private let queueKey = DispatchSpecificKey<Void>()
    // Allocated once for the lifetime of the monitor so a late real-time
    // callback can never observe storage that was freed during a restart.
    private let counters: OpaquePointer? = CGRTSignalCountersCreate()
    private var timer: DispatchSourceTimer?
    private var registrations: [ListenerRegistration] = []
    private var outputRegistrations: [ListenerRegistration] = []
    private var currentDeviceID: AudioObjectID = kAudioObjectUnknown
    private var isRunning = false
    /// When something last arrived. Drives the drain interval; see
    /// `DrainSchedule` for why backing off cannot lose a signal.
    private var lastSignalDate = Date()
    private var currentDrainInterval: TimeInterval = DrainSchedule.active

    var onBatch: BatchHandler?
    var onError: ErrorHandler?

    init() {
        controlQueue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
        if let counters {
            CGRTSignalCountersDestroy(counters)
        }
    }

    func start() throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try startLocked()
        } else {
            try controlQueue.sync {
                try startLocked()
            }
        }
    }

    func stop() {
        let work = { [self] in stopLocked() }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            controlQueue.sync(execute: work)
        }
    }

    func restart() throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
            try startLocked()
        } else {
            try controlQueue.sync {
                stopLocked()
                try startLocked()
            }
        }
    }

    /// Whether any property listener is currently installed.
    ///
    /// `rebuildListenersLocked()` deliberately removes every registration when
    /// a rebuild fails part-way, so this can be `false` while `isRunning` is
    /// still `true`: Fennec has a timer and no ears. The app has to be able
    /// to tell the difference, because that state used to render as
    /// "Listening" forever.
    var isAttached: Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return !registrations.isEmpty
        }
        return controlQueue.sync { !registrations.isEmpty }
    }

    func refreshDeviceSnapshot() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.reattachToDefaultOutputLocked()
            } catch {
                self.onError?(error)
            }
        }
    }

    private func startLocked() throws {
        guard !isRunning else { return }
        guard counters != nil else {
            throw CoreAudioMonitorError.allocationFailed
        }

        do {
            try installRequiredListenerLocked(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                preferredScopes: [kAudioObjectPropertyScopeGlobal]
            )
            try installOptionalListenerLocked(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyServiceRestarted,
                preferredScopes: [kAudioObjectPropertyScopeGlobal]
            )
            try reattachToDefaultOutputLocked()
            startTimerLocked()
            isRunning = true
        } catch {
            stopLocked()
            throw error
        }
    }

    private func stopLocked() {
        guard isRunning || !registrations.isEmpty else { return }
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil

        removeLocked(registrations)
        registrations.removeAll()
        outputRegistrations.removeAll()
        currentDeviceID = kAudioObjectUnknown

        // Clear any notifications that arrived while listeners were being removed.
        if let counters {
            var overloads: UInt64 = 0
            var abnormalStops: UInt64 = 0
            var defaultOutputChanges: UInt64 = 0
            var sampleRateChanges: UInt64 = 0
            var deviceStateChanges: UInt64 = 0
            var serviceRestarts: UInt64 = 0
            CGRTSignalCountersDrain(
                counters,
                &overloads,
                &abnormalStops,
                &defaultOutputChanges,
                &sampleRateChanges,
                &deviceStateChanges,
                &serviceRestarts
            )
        }
        isRunning = false
    }

    private func startTimerLocked() {
        lastSignalDate = Date()
        currentDrainInterval = DrainSchedule.active
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        scheduleLocked(timer, interval: DrainSchedule.active)
        timer.setEventHandler { [weak self] in
            self?.drainLocked()
        }
        self.timer = timer
        timer.resume()
    }

    private func scheduleLocked(_ timer: DispatchSourceTimer, interval: TimeInterval) {
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(DrainSchedule.leeway(for: interval) * 1_000))
        )
    }

    /// Steps the drain interval up or down. Only reschedules when the tier
    /// actually changes, so a quiet machine reschedules twice an hour rather
    /// than four times a second.
    private func adjustDrainIntervalLocked(sawSignal: Bool) {
        let now = Date()
        if sawSignal { lastSignalDate = now }

        let desired = DrainSchedule.interval(quietFor: now.timeIntervalSince(lastSignalDate))
        guard desired != currentDrainInterval, let timer else { return }
        currentDrainInterval = desired
        scheduleLocked(timer, interval: desired)
    }

    private func drainLocked() {
        guard let counters else { return }

        var overloads: UInt64 = 0
        var abnormalStops: UInt64 = 0
        var defaultOutputChanges: UInt64 = 0
        var sampleRateChanges: UInt64 = 0
        var deviceStateChanges: UInt64 = 0
        var serviceRestarts: UInt64 = 0
        CGRTSignalCountersDrain(
            counters,
            &overloads,
            &abnormalStops,
            &defaultOutputChanges,
            &sampleRateChanges,
            &deviceStateChanges,
            &serviceRestarts
        )

        let sawSignal = overloads > 0 || abnormalStops > 0 || defaultOutputChanges > 0
            || sampleRateChanges > 0 || deviceStateChanges > 0 || serviceRestarts > 0
        adjustDrainIntervalLocked(sawSignal: sawSignal)
        guard sawSignal else { return }

        if serviceRestarts > 0 {
            // A Core Audio service reset invalidates every cached object and
            // listener, including system-object listeners. Rebuild the full
            // listener graph rather than only reattaching the output device.
            do {
                try rebuildListenersLocked()
            } catch {
                onError?(error)
            }
        } else if defaultOutputChanges > 0 || deviceStateChanges > 0 {
            do {
                try reattachToDefaultOutputLocked()
            } catch {
                onError?(error)
            }
        }

        let snapshot: AudioDeviceSnapshot
        do {
            snapshot = try CoreAudioReader.defaultOutputSnapshot()
        } catch {
            snapshot = .unavailable
            onError?(error)
        }

        let batch = AudioSignalBatch(
            date: Date(),
            overloads: overloads,
            abnormalStops: abnormalStops,
            defaultOutputChanges: defaultOutputChanges,
            sampleRateChanges: sampleRateChanges,
            deviceStateChanges: deviceStateChanges,
            serviceRestarts: serviceRestarts,
            device: snapshot
        )
        onBatch?(batch)
    }

    private func rebuildListenersLocked() throws {
        let oldRegistrations = registrations
        removeLocked(oldRegistrations)
        registrations.removeAll()
        outputRegistrations.removeAll()
        currentDeviceID = kAudioObjectUnknown

        do {
            try installRequiredListenerLocked(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                preferredScopes: [kAudioObjectPropertyScopeGlobal]
            )
            try installOptionalListenerLocked(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyServiceRestarted,
                preferredScopes: [kAudioObjectPropertyScopeGlobal]
            )
            try reattachToDefaultOutputLocked()
        } catch {
            // A service restart invalidates all old object IDs. If rebuilding
            // fails midway, remove every newly installed listener so a later
            // explicit monitor restart starts from a clean state.
            let partialRegistrations = registrations
            removeLocked(partialRegistrations)
            registrations.removeAll()
            outputRegistrations.removeAll()
            currentDeviceID = kAudioObjectUnknown
            throw error
        }
    }

    private func reattachToDefaultOutputLocked() throws {
        let previousOutputRegistrations = outputRegistrations
        removeLocked(previousOutputRegistrations)
        registrations.removeAll { previousOutputRegistrations.contains($0) }
        outputRegistrations.removeAll()

        let newDeviceID = try CoreAudioReader.defaultOutputDeviceID()
        currentDeviceID = newDeviceID
        guard newDeviceID != kAudioObjectUnknown else { return }

        do {
            try installOutputListenerLocked(
                objectID: newDeviceID,
                selector: kAudioDeviceProcessorOverload,
                preferredScopes: [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal],
                required: true
            )
            try installOutputListenerLocked(
                objectID: newDeviceID,
                selector: kAudioDevicePropertyIOStoppedAbnormally,
                preferredScopes: [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal],
                required: false
            )
            try installOutputListenerLocked(
                objectID: newDeviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                preferredScopes: [kAudioObjectPropertyScopeGlobal],
                required: false
            )
            try installOutputListenerLocked(
                objectID: newDeviceID,
                selector: kAudioDevicePropertyDeviceIsAlive,
                preferredScopes: [kAudioObjectPropertyScopeGlobal],
                required: false
            )
            try installOutputListenerLocked(
                objectID: newDeviceID,
                selector: kAudioDevicePropertyDeviceHasChanged,
                preferredScopes: [kAudioObjectPropertyScopeGlobal],
                required: false
            )
        } catch {
            // Do not leave a partially attached device behind. The system-level
            // default-output listener remains active so a later device change can recover.
            let partialRegistrations = outputRegistrations
            removeLocked(partialRegistrations)
            registrations.removeAll { partialRegistrations.contains($0) }
            outputRegistrations.removeAll()
            currentDeviceID = kAudioObjectUnknown
            throw error
        }
    }

    private func installRequiredListenerLocked(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        preferredScopes: [AudioObjectPropertyScope]
    ) throws {
        guard let scope = preferredScopes.first(where: {
            CoreAudioReader.hasProperty(objectID: objectID, selector: selector, scope: $0)
        }) else {
            throw CoreAudioMonitorError.listenerFailed(selector: selector, status: kAudioHardwareUnknownPropertyError)
        }
        try addLocked(objectID: objectID, selector: selector, scope: scope, outputSpecific: false)
    }

    private func installOptionalListenerLocked(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        preferredScopes: [AudioObjectPropertyScope]
    ) throws {
        guard let scope = preferredScopes.first(where: {
            CoreAudioReader.hasProperty(objectID: objectID, selector: selector, scope: $0)
        }) else { return }
        try addLocked(objectID: objectID, selector: selector, scope: scope, outputSpecific: false)
    }

    private func installOutputListenerLocked(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        preferredScopes: [AudioObjectPropertyScope],
        required: Bool
    ) throws {
        guard let scope = preferredScopes.first(where: {
            CoreAudioReader.hasProperty(objectID: objectID, selector: selector, scope: $0)
        }) else {
            if required {
                throw CoreAudioMonitorError.listenerFailed(selector: selector, status: kAudioHardwareUnknownPropertyError)
            }
            return
        }
        try addLocked(objectID: objectID, selector: selector, scope: scope, outputSpecific: true)
    }

    private func addLocked(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        outputSpecific: Bool
    ) throws {
        guard let counters else { throw CoreAudioMonitorError.allocationFailed }
        let registration = ListenerRegistration(
            objectID: objectID,
            selector: selector,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        let status = CGAudioAddPropertyListener(
            registration.objectID,
            registration.selector,
            registration.scope,
            registration.element,
            counters
        )
        guard status == noErr else {
            throw CoreAudioMonitorError.listenerFailed(selector: selector, status: status)
        }
        registrations.append(registration)
        if outputSpecific {
            outputRegistrations.append(registration)
        }
    }

    private func removeLocked(_ registrationsToRemove: [ListenerRegistration]) {
        guard let counters else { return }
        for registration in registrationsToRemove {
            _ = CGAudioRemovePropertyListener(
                registration.objectID,
                registration.selector,
                registration.scope,
                registration.element,
                counters
            )
        }
    }
}
