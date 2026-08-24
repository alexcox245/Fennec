import AppKit
import Foundation

struct ManualRepairWarning: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

enum MonitoringState: Equatable {
    case starting
    case monitoring
    case stopped
    case failed(String)

    var title: String {
        switch self {
        case .starting: return "Starting"
        case .monitoring: return "Listening"
        case .stopped: return "Stopped"
        case .failed: return "Monitor failed"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var monitoringState: MonitoringState = .starting
    @Published private(set) var currentDevice: AudioDeviceSnapshot = .unavailable
    @Published private(set) var overloadSignalCount: UInt64 = 0
    @Published private(set) var abnormalStopCount: UInt64 = 0
    @Published private(set) var detectionCount = 0
    @Published private(set) var lastDetectionDate: Date?
    @Published private(set) var lastDetectionReason: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isRepairing = false
    @Published private(set) var recentActivity: [ActivityRecord] = []
    @Published var manualRepairWarning: ManualRepairWarning?

    let settings: SettingsStore
    let helperManager: HelperManager
    let loginItemManager: LoginItemManager
    let repairHistory: RepairHistoryStore
    let notificationController: NotificationController

    private let monitor = CoreAudioMonitor()
    private let detectionEngine = DetectionEngine()
    private let safetyChecker = RecoverySafetyChecker()
    private let eventLogger = EventLogger()
    private var suppressSignalsUntil = Date.distantPast
    private var detectionTaskActive = false

    init() {
        settings = SettingsStore()
        helperManager = HelperManager()
        loginItemManager = LoginItemManager()
        repairHistory = RepairHistoryStore()
        notificationController = NotificationController()

        notificationController.onRepairRequested = { [weak self] in
            self?.requestManualRepair()
        }
        notificationController.requestAuthorization()

        monitor.onBatch = { [weak self] batch in
            Task { @MainActor in
                self?.handle(batch)
            }
        }
        monitor.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleMonitorError(error)
            }
        }

        startMonitoring()
    }

    deinit {
        monitor.stop()
    }

    // MARK: Derived state

    var repairCount: Int { repairHistory.summary.successes }

    var lastRepair: RepairRecord? { repairHistory.records.first }

    var lastSuccessfulRepair: RepairRecord? { repairHistory.lastSuccessfulRepair }

    var lastRepairDate: Date? { lastSuccessfulRepair?.date }

    var menuBarSymbol: String {
        if isRepairing { return "arrow.triangle.2.circlepath" }
        switch monitoringState {
        case .monitoring: return "waveform"
        case .starting: return "ellipsis.circle"
        case .stopped: return "waveform.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var statusDetail: String {
        switch monitoringState {
        case .starting:
            return "Attaching to the current Core Audio output device…"
        case .monitoring:
            return "Watching \(currentDevice.name) for missed real-time deadlines."
        case .stopped:
            return "Crackle detection is stopped."
        case .failed(let message):
            return message
        }
    }

    /// True when Fennec can repair on its own without asking for anything.
    var isArmed: Bool {
        settings.autoRepairEnabled && helperManager.state.isReachable
    }

    // MARK: Setup readiness

    var setupSteps: [SetupStep] {
        SetupChecklist.steps(
            helper: helperManager.state,
            loginItem: loginItemManager.state,
            notificationsAuthorized: notificationController.isAuthorized
        )
    }

    var remainingSetupSteps: [SetupStep] {
        SetupChecklist.remaining(
            helper: helperManager.state,
            loginItem: loginItemManager.state,
            notificationsAuthorized: notificationController.isAuthorized
        )
    }

    var isFullySetUp: Bool {
        SetupChecklist.isReady(helper: helperManager.state, loginItem: loginItemManager.state)
    }

    var setupSummary: String {
        SetupChecklist.summary(
            helper: helperManager.state,
            loginItem: loginItemManager.state,
            notificationsAuthorized: notificationController.isAuthorized
        )
    }

    /// The single entry point for every setup button in the app, so the
    /// popover, Settings, and the first-run window cannot disagree about what
    /// "Turn On" means.
    func performSetupAction(for step: SetupStep) {
        switch step.kind {
        case .helper:
            helperManager.register()
        case .helperApproval:
            helperManager.openApprovalSettings()
        case .loginItem:
            if loginItemManager.state.requiresApproval {
                loginItemManager.openSettings()
            } else {
                loginItemManager.enable()
            }
        case .notifications:
            notificationController.openSystemSettings()
        }
    }

    // MARK: Monitoring lifecycle

    func startMonitoring() {
        monitoringState = .starting
        do {
            try monitor.start()
            monitoringState = .monitoring
            refreshCurrentDevice()
            record(.init(kind: .monitorStarted, summary: "Core Audio monitoring started."))
        } catch {
            monitoringState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            record(.init(kind: .monitorError, summary: error.localizedDescription))
        }
    }

    func stopMonitoring() {
        monitor.stop()
        monitoringState = .stopped
    }

    func restartMonitoring() {
        monitor.stop()
        detectionEngine.reset()
        startMonitoring()
    }

    func refreshAll() {
        refreshCurrentDevice()
        helperManager.refreshStatus(testReachability: true)
        loginItemManager.refresh()
        notificationController.refreshAuthorization()
        repairHistory.refreshSummary()
    }

    // MARK: User-initiated repair

    func requestManualRepair() {
        guard !isRepairing else { return }
        Task {
            let protectMicrophone = settings.protectMicrophone
            let protectApps = settings.protectCommunicationApps
            let report = await Task.detached(priority: .utility) { [safetyChecker] in
                safetyChecker.evaluate(
                    protectMicrophone: protectMicrophone,
                    protectCommunicationApps: protectApps
                )
            }.value

            if report.canAutoRepair {
                await performRepair(trigger: .manual, decision: nil)
            } else {
                manualRepairWarning = ManualRepairWarning(
                    message: report.blockers.joined(separator: "\n\n")
                        + "\n\nRestarting Core Audio briefly disconnects playback and recording."
                )
            }
        }
    }

    func confirmManualRepair() {
        manualRepairWarning = nil
        Task { await performRepair(trigger: .manual, decision: nil) }
    }

    func cancelManualRepair() {
        manualRepairWarning = nil
    }

    func openEventLog() {
        NSWorkspace.shared.activateFileViewerSelecting([eventLogger.logURL])
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Signal handling

    private func handle(_ batch: AudioSignalBatch) {
        currentDevice = batch.device

        if batch.serviceRestarts > 0 {
            detectionEngine.reset()
            suppressSignalsUntil = max(suppressSignalsUntil, batch.date.addingTimeInterval(12))
            record(.init(
                kind: .serviceRestarted,
                summary: "Core Audio restarted; monitoring listeners were rebuilt.",
                details: ["count": String(batch.serviceRestarts)],
                date: batch.date
            ))
        }

        if batch.defaultOutputChanges > 0 || batch.sampleRateChanges > 0 || batch.deviceStateChanges > 0 {
            // Device switches, wake transitions, and format renegotiation can
            // legitimately produce transient stop/overload notifications. Give
            // the graph two seconds to settle before treating them as crackle.
            detectionEngine.reset()
            suppressSignalsUntil = max(suppressSignalsUntil, batch.date.addingTimeInterval(2))
        }

        if batch.defaultOutputChanges > 0 || batch.deviceStateChanges > 0 {
            record(.init(
                kind: .deviceChanged,
                summary: "Audio output changed to \(batch.device.name).",
                details: deviceDetails(batch.device),
                date: batch.date
            ))
        }

        if batch.overloads > 0 {
            overloadSignalCount += batch.overloads
            record(.init(
                kind: .signal,
                summary: "Core Audio processor overload signal received.",
                details: [
                    "count": String(batch.overloads),
                    "device": batch.device.name,
                    "sampleRate": String(format: "%.0f", batch.device.sampleRate)
                ],
                date: batch.date
            ))
        }

        if batch.abnormalStops > 0 {
            abnormalStopCount += batch.abnormalStops
            record(.init(
                kind: .signal,
                summary: "Core Audio I/O stopped abnormally.",
                details: ["count": String(batch.abnormalStops), "device": batch.device.name],
                date: batch.date
            ))
        }

        guard batch.serviceRestarts == 0 else { return }
        guard batch.containsFailureSignal, batch.date >= suppressSignalsUntil else { return }
        guard let decision = detectionEngine.ingest(batch, sensitivity: settings.sensitivity) else { return }

        detectionCount += 1
        lastDetectionDate = batch.date
        lastDetectionReason = decision.reason
        record(.init(
            kind: .detection,
            summary: decision.reason,
            details: [
                "signal": decision.signal.rawValue,
                "signalCount": String(decision.signalCount),
                "elapsedSeconds": String(format: "%.2f", decision.elapsedSeconds),
                "device": batch.device.name,
                "transport": batch.device.transport.rawValue
            ],
            date: batch.date
        ))

        guard !detectionTaskActive else { return }
        detectionTaskActive = true
        Task {
            defer { detectionTaskActive = false }
            await respondToDetection(decision, device: batch.device)
        }
    }

    /// Everything between "Fennec is sure the audio is broken" and "Fennec
    /// restarts Core Audio". Every early return is a refusal the user is
    /// entitled to see, so each one records a reason.
    private func respondToDetection(_ decision: DetectionDecision, device: AudioDeviceSnapshot) async {
        guard settings.autoRepairEnabled else {
            recordSkipped("Automatic repair is turned off.")
            notifyUnrepaired(decision, blocker: "Automatic repair is turned off.")
            return
        }

        guard !isRepairing else {
            recordSkipped("A repair is already running.")
            return
        }

        if settings.skipBluetooth && device.transport.isBluetooth {
            let blocker = "Automatic repair is set to skip Bluetooth outputs."
            recordSkipped(blocker)
            notifyUnrepaired(decision, blocker: blocker)
            return
        }

        if let lastRepairDate {
            let elapsed = Date().timeIntervalSince(lastRepairDate)
            if elapsed < settings.cooldownSeconds {
                let remaining = Int(ceil(settings.cooldownSeconds - elapsed))
                // Deliberately silent: the user was told about the repair that
                // started this cooldown seconds ago.
                recordSkipped("Repair cooldown is active for another \(remaining) seconds.")
                return
            }
        }

        guard helperManager.state.isReachable else {
            let blocker = "The automatic repair helper is not enabled."
            recordSkipped(blocker)
            notifyUnrepaired(decision, blocker: blocker)
            return
        }

        let protectMicrophone = settings.protectMicrophone
        let protectApps = settings.protectCommunicationApps
        let report = await Task.detached(priority: .utility) { [safetyChecker] in
            safetyChecker.evaluate(
                protectMicrophone: protectMicrophone,
                protectCommunicationApps: protectApps
            )
        }.value

        guard report.canAutoRepair else {
            let blocker = report.blockers.joined(separator: " ")
            recordSkipped(blocker)
            notifyUnrepaired(decision, blocker: blocker)
            return
        }

        await performRepair(trigger: .automatic, decision: decision)
    }

    // MARK: The repair itself

    private func performRepair(trigger: RepairRecord.Trigger, decision: DetectionDecision?) async {
        guard !isRepairing else { return }
        isRepairing = true
        detectionEngine.reset()
        suppressSignalsUntil = Date().addingTimeInterval(12)

        let device = currentDevice
        let automatic = trigger == .automatic
        record(.init(
            kind: .repairRequested,
            summary: automatic ? "Automatic Core Audio repair requested." : "Manual Core Audio repair requested."
        ))

        // Measured across the privileged call only, so it reflects the audio
        // gap the user heard rather than Fennec's own bookkeeping.
        let started = Date()

        do {
            let message: String
            if automatic {
                message = try await helperManager.restartCoreAudio()
            } else if helperManager.state.isEnabled {
                do {
                    message = try await helperManager.restartCoreAudio()
                } catch {
                    message = try await PrivilegedPromptRepair.restartCoreAudio()
                }
            } else {
                message = try await PrivilegedPromptRepair.restartCoreAudio()
            }

            let repair = makeRecord(
                trigger: trigger,
                decision: decision,
                device: device,
                duration: Date().timeIntervalSince(started),
                succeeded: true,
                message: message
            )
            repairHistory.record(repair)
            lastError = nil
            record(.init(
                kind: .repairSucceeded,
                summary: message,
                details: repairDetails(repair)
            ))
            if settings.notifyOnRepair {
                notificationController.postRepairResult(repair)
            }

            try? await Task.sleep(for: .milliseconds(1200))
            do {
                try monitor.restart()
                monitoringState = .monitoring
                refreshCurrentDevice()
            } catch {
                monitoringState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
                record(.init(kind: .monitorError, summary: error.localizedDescription))
            }
        } catch {
            let repair = makeRecord(
                trigger: trigger,
                decision: decision,
                device: device,
                duration: Date().timeIntervalSince(started),
                succeeded: false,
                message: error.localizedDescription
            )
            repairHistory.record(repair)
            lastError = error.localizedDescription
            record(.init(
                kind: .repairFailed,
                summary: error.localizedDescription,
                details: repairDetails(repair)
            ))
            // Always surfaced: a failed repair is the one case where the user
            // has to do something.
            notificationController.postRepairResult(repair)
        }

        isRepairing = false
    }

    private func makeRecord(
        trigger: RepairRecord.Trigger,
        decision: DetectionDecision?,
        device: AudioDeviceSnapshot,
        duration: TimeInterval,
        succeeded: Bool,
        message: String
    ) -> RepairRecord {
        RepairRecord(
            trigger: trigger,
            signal: decision?.signal,
            signalCount: decision?.signalCount ?? 0,
            elapsedSeconds: decision?.elapsedSeconds ?? 0,
            deviceName: device.name,
            transport: device.transport,
            durationSeconds: duration,
            succeeded: succeeded,
            message: message
        )
    }

    private func repairDetails(_ repair: RepairRecord) -> [String: String] {
        [
            "trigger": repair.trigger.rawValue,
            "device": repair.deviceName,
            "transport": repair.transport.rawValue,
            "durationSeconds": String(format: "%.2f", repair.durationSeconds),
            "signalCount": String(repair.signalCount)
        ]
    }

    // MARK: Plumbing

    private func refreshCurrentDevice() {
        do {
            currentDevice = try CoreAudioReader.defaultOutputSnapshot()
        } catch {
            currentDevice = .unavailable
            lastError = error.localizedDescription
        }
    }

    private func handleMonitorError(_ error: Error) {
        lastError = error.localizedDescription
        record(.init(kind: .monitorError, summary: error.localizedDescription))
    }

    private func notifyUnrepaired(_ decision: DetectionDecision, blocker: String?) {
        guard settings.notifyOnDetection else { return }
        notificationController.postUnrepairedDetection(reason: decision.reason, blocker: blocker)
    }

    private func recordSkipped(_ summary: String) {
        record(.init(kind: .repairSkipped, summary: summary))
    }

    private func record(_ activity: ActivityRecord) {
        recentActivity.insert(activity, at: 0)
        if recentActivity.count > 30 {
            recentActivity.removeLast(recentActivity.count - 30)
        }
        eventLogger.append(activity)
    }

    private func deviceDetails(_ device: AudioDeviceSnapshot) -> [String: String] {
        [
            "name": device.name,
            "uid": device.uid,
            "sampleRate": String(format: "%.0f", device.sampleRate),
            "transport": device.transport.rawValue,
            "isAlive": String(device.isAlive)
        ]
    }
}
