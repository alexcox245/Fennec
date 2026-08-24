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
        case .monitoring: return "Monitoring"
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
    @Published private(set) var repairCount = 0
    @Published private(set) var lastDetectionDate: Date?
    @Published private(set) var lastDetectionReason: String?
    @Published private(set) var lastRepairDate: Date?
    @Published private(set) var lastRepairMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isRepairing = false
    @Published private(set) var recentActivity: [ActivityRecord] = []
    @Published var manualRepairWarning: ManualRepairWarning?

    let settings: SettingsStore
    let helperManager: HelperManager
    let loginItemManager: LoginItemManager

    private let monitor = CoreAudioMonitor()
    private let detectionEngine = DetectionEngine()
    private let safetyChecker = RecoverySafetyChecker()
    private let eventLogger = EventLogger()
    private let notificationController = NotificationController()
    private var suppressSignalsUntil = Date.distantPast
    private var detectionTaskActive = false

    init() {
        settings = SettingsStore()
        helperManager = HelperManager()
        loginItemManager = LoginItemManager()

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
    }

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
                await performRepair(automatic: false)
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
        Task { await performRepair(automatic: false) }
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

    private func respondToDetection(_ decision: DetectionDecision, device: AudioDeviceSnapshot) async {
        guard settings.autoRepairEnabled else {
            recordSkipped("Automatic repair is disabled.")
            notifyDetection(reason: decision.reason, skipped: true)
            return
        }

        guard !isRepairing else {
            recordSkipped("A repair is already running.")
            return
        }

        if settings.skipBluetooth && device.transport.isBluetooth {
            recordSkipped("Automatic repair was skipped for a Bluetooth output device.")
            notifyDetection(reason: decision.reason, skipped: true)
            return
        }

        if let lastRepairDate {
            let elapsed = Date().timeIntervalSince(lastRepairDate)
            if elapsed < settings.cooldownSeconds {
                let remaining = Int(ceil(settings.cooldownSeconds - elapsed))
                recordSkipped("Repair cooldown is active for another \(remaining) seconds.")
                return
            }
        }

        guard helperManager.state.isReachable else {
            recordSkipped("The privileged repair helper is not ready.")
            notifyDetection(reason: decision.reason, skipped: true)
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
            let reason = report.blockers.joined(separator: " ")
            recordSkipped(reason)
            notifyDetection(reason: "\(decision.reason) \(reason)", skipped: true)
            return
        }

        await performRepair(automatic: true)
    }

    private func performRepair(automatic: Bool) async {
        guard !isRepairing else { return }
        isRepairing = true
        detectionEngine.reset()
        suppressSignalsUntil = Date().addingTimeInterval(12)

        record(.init(
            kind: .repairRequested,
            summary: automatic ? "Automatic Core Audio repair requested." : "Manual Core Audio repair requested."
        ))

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

            lastRepairDate = Date()
            lastRepairMessage = message
            lastError = nil
            repairCount += 1
            record(.init(kind: .repairSucceeded, summary: message))
            notificationController.postRepairResult(success: true, message: message)

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
            lastError = error.localizedDescription
            lastRepairMessage = nil
            record(.init(kind: .repairFailed, summary: error.localizedDescription))
            notificationController.postRepairResult(success: false, message: error.localizedDescription)
        }

        isRepairing = false
    }

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

    private func notifyDetection(reason: String, skipped: Bool) {
        guard settings.notifyOnDetection else { return }
        notificationController.postDetection(reason: reason, automaticRepairWasSkipped: skipped)
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
