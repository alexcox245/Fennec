import AppKit
import Darwin
import Foundation

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
    /// The raw material for the popover's rolling graph: recent overload
    /// signal timestamps (both witnesses) and clean playback-stall stops,
    /// pruned as they age out of every window that reads them.
    @Published private(set) var recentOverloadDates: [Date] = []
    @Published private(set) var recentStallDates: [Date] = []
    /// One date per second the output device was actually running IO. The
    /// graph paints these as its activity ribbon; a hole in them is a
    /// playback gap the user can point at.
    @Published private(set) var recentAudioActivity: [Date] = []
    @Published private(set) var detectionCount = 0
    @Published private(set) var lastDetectionDate: Date?
    @Published private(set) var lastDetectionReason: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isRepairing = false
    @Published private(set) var recentActivity: [ActivityRecord] = []
    @Published var manualRepairWarning: ManualRepairWarning?
    @Published var administratorRepairRequest: AdministratorRepairRequest?
    @Published private(set) var promptedRepair: DetectedRepairPrompt?
    /// The id of the most recent repair this launch produced, so a window can
    /// show *the repair the user just ran* rather than the newest record of
    /// any kind from any day.
    @Published private(set) var lastRepairID: UUID?
    @Published private(set) var hasCompletedOnboardingRepair = false
    @Published private(set) var onboardingFoxRequestCount = 0
    @Published private(set) var manualFoxRequestCount = 0
    @Published private(set) var previewFoxRequestCount = 0
    /// The helper's rate limiter, phrased for the user. Transient.
    @Published private(set) var throttleNotice: String?
    /// True between pressing Repair Audio Now and the safety scan returning.
    /// Under heavy load (which is Fennec's own premise) that gap is long
    /// enough that the button looked untouched.
    @Published private(set) var isPreparingRepair = false

    let settings: SettingsStore
    let helperManager: HelperManager
    let loginItemManager: LoginItemManager
    let repairHistory: RepairHistoryStore
    let notificationController: NotificationController
    weak var updaterController: FennecUpdater?

    private let monitor = CoreAudioMonitor()
    private let logMonitor = SystemLogMonitor()
    private let detectionEngine = DetectionEngine()
    private let safetyChecker = RecoverySafetyChecker()
    private let eventLogger = EventLogger()
    private let systemEvents = SystemEventObserver()
    private var faultEpisodes = FaultEpisodePolicy()
    private var notifiedRepairEpisodeID: UUID?
    private var decisionByEpisode: [UUID: DetectionDecision] = [:]
    private var deviceUIDByEpisode: [UUID: String] = [:]
    private var pendingManualDecision: DetectionDecision?
    private var pendingManualEpisodeID: UUID?
    private var pendingManualDeviceUID: String?
    private var suppressSignalsUntil = Date.distantPast
    private var detectionTaskActive = false
    /// Keyed on the last *attempt*, not the last success. A machine whose
    /// repairs keep failing needs the cooldown more than one whose repairs
    /// work, not less.
    private var lastRepairAttemptDate: Date?
    private var detectionNotificationBudget = NotificationBudget()
    /// Half an hour between stall advisories. The condition persists for as
    /// long as the machine is busy, and being told twice is being nagged.
    private var stallNotificationBudget = NotificationBudget(minimumInterval: 1800)
    private var pauseTimer: Timer?
    private var monitorRecoveryInFlight = false
    private var rehearsalRequested = false
    private var onboardingFoxStarted = false
    private var manualFoxBurstID: UUID?
    private var manualFoxBurstStarted = false
    private var previewFoxBurstID: UUID?
    private var updaterInstallationPending = false
    private var updatePreparationID: UUID?
    private var updatePreparationCancelled = false
    private var verificationTimer: Timer?
    private var verifyingRepairID: UUID?
    private var announcedStandDownUntil: Date?
    /// When Fennec may rebuild a helper registration that macOS reports
    /// enabled but that is not answering. The decision lives in the pure
    /// policy; the attempt lives in `healSilentHelper`.
    private var helperHealPolicy = HelperHealPolicy()

    init() {
        settings = SettingsStore()
        helperManager = HelperManager()
        loginItemManager = LoginItemManager()
        loginItemManager.configureDefaultIfNeeded(
            hasCompletedFirstRun: settings.hasCompletedFirstRun,
            installLocation: InstallLocation.current()
        )
        repairHistory = RepairHistoryStore()
        notificationController = NotificationController()
        WindowPresenter.shared.configureRepairFox(settings: settings)
        WindowPresenter.shared.onManualFoxBurstFinished = { [weak self] id in
            guard let self else { return }
            if self.manualFoxBurstID == id {
                self.manualFoxBurstID = nil
                self.manualFoxBurstStarted = false
                self.manualFoxRequestCount = 0
            } else if self.previewFoxBurstID == id {
                self.previewFoxBurstID = nil
                self.previewFoxRequestCount = 0
            }
        }

        notificationController.onRepairRequested = { [weak self] episodeID in
            if let episodeID {
                // The notification click is the repair decision. Keep the
                // safety scan, then let macOS ask for a password if needed.
                self?.requestManualRepair(for: episodeID, approvedByNotification: true)
            } else {
                self?.requestRepairButton()
            }
        }
        notificationController.onIgnoreRequested = { [weak self] episodeID in
            guard let episodeID else { return }
            self?.dismissDetectedRepairPrompt(episodeID: episodeID)
        }
        notificationController.onShowActivityRequested = { [weak self] in
            guard let self else { return }
            WindowPresenter.shared.showActivity(model: self)
        }
        notificationController.refreshAuthorization()

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

        logMonitor.onOverloads = { [weak self] eventDates in
            Task { @MainActor in
                self?.handleLogOverloads(eventDates: eventDates)
            }
        }
        logMonitor.onError = { [weak self] error in
            Task { @MainActor in
                // The listener path is unaffected, so this is a note in the
                // record, not a monitoring failure.
                self?.record(.init(kind: .monitorError, summary: error.localizedDescription))
            }
        }
        logMonitor.onIOStateChanges = { [weak self] stops, _ in
            Task { @MainActor in
                self?.handleIOStops(stops)
            }
        }
        logMonitor.onActivitySample = { [weak self] date in
            Task { @MainActor in
                self?.ingestActivitySample(date)
            }
        }
        logMonitor.onSuccessfulCoverage = { [weak self] from, through, eventDates in
            Task { @MainActor in
                self?.handleSuccessfulLogCoverage(from: from, through: through, eventDates: eventDates)
            }
        }

        systemEvents.onEvent = { [weak self] event in
            self?.beQuiet(for: event)
        }

        // The delegate needs the model before any window can be opened, and
        // the popover's onAppear is too late: it does not run until someone
        // clicks the menu-bar item, which is exactly the thing a user who
        // cannot find the app has not done.
        AppDelegate.model = self

        refreshStandDown()

        // Resolve any pause that expired while Fennec was not running.
        pauseState = settings.pauseState.resolved()
        settings.pauseState = pauseState
        schedulePauseExpiry()

        // Dismissing the first-run window counts, however it is dismissed.
        // Before this, `completeFirstRun()` had exactly one caller, the Done
        // button, so closing it with the red button or ⌘W (the gestures macOS
        // makes most available) meant a 620×720 window and a Dock icon shoved
        // in front of the user at every login, forever.
        WindowPresenter.shared.onWindowClosed = { [weak self] id in
            switch id {
            case WindowPresenter.ID.welcome:
                self?.completeFirstRun()
                if self?.manualFoxBurstID == nil {
                    WindowPresenter.shared.resetOnboardingFox()
                }
            case WindowPresenter.ID.repairPrompt:
                if let episodeID = self?.promptedRepair?.episodeID {
                    self?.dismissDetectedRepairPrompt(episodeID: episodeID, closeWindow: false)
                }
            case WindowPresenter.ID.about:
                self?.updaterController?.driver.cancelForWindowClose()
            default:
                break
            }
        }

        if UserDefaults.standard.bool(forKey: FennecUpdater.helperWasRegisteredKey) {
            Task { [weak self] in
                guard let self else { return }
                let restored = await helperManager.restoreRegistrationAfterUpdate()
                if !restored {
                    settings.repairMode = .askFirst
                }
                UserDefaults.standard.removeObject(forKey: FennecUpdater.helperWasRegisteredKey)
            }
        }

        if !settings.hasCompletedFirstRun {
            // Next run loop turn: the scene has not finished building yet, and
            // opening a window from inside a StateObject's init is a good way
            // to get a window that never becomes key.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                WindowPresenter.shared.showWelcome(model: self)
            }
        }

        startMonitoring()
        // The graph Fennec just attached to may already have signals queued
        // against it, and a login launch lands in the middle of the same
        // renegotiation a wake does.
        beQuiet(for: .launch, log: false)

        // Automatic mode may repair an enabled-but-silent helper at launch.
        // Ask me first must not touch helper registration in the background.
        if settings.repairMode == .automatic {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.settings.repairMode == .automatic else { return }
                _ = await self.healSilentHelper(userInitiated: false)
            }
        }
    }

    deinit {
        monitor.stop()
        logMonitor.stop()
    }

    // MARK: Derived state

    var repairCount: Int { repairHistory.summary.successes }

    var lastRepair: RepairRecord? { repairHistory.records.first }

    var lastSuccessfulRepair: RepairRecord? { repairHistory.lastSuccessfulRepair }

    var lastRepairDate: Date? { lastSuccessfulRepair?.date }

    /// The sign on the wall. Recomputed on demand rather than cached, because
    /// it changes at midnight and nothing else needs to know when that is.
    var daysWithoutIncident: DaysWithoutIncident {
        DaysWithoutIncident.make(
            records: repairHistory.records,
            listeningSince: settings.listeningSince
        )
    }

    func showActivityWindow() {
        WindowPresenter.shared.showActivity(model: self)
    }

    /// The menu bar is Fennec's only persistent channel. A banner auto-
    /// dismisses and a sound played through a broken audio system was never an
    /// escalation at all, so anything that needs the user leaves a visible
    /// mark here until they look.
    var menuBarIconState: MenuBarIconState {
        if isRepairing { return .repairing }
        // The red mark: crackle signals are arriving and Fennec is on the
        // case. Above attention because it describes right now; below the
        // pause, because a paused Fennec promising action would be a lie.
        if isCrackleWatchActive && !isPaused { return .detected }
        // An unanswered question is a reason to look at Fennec, and the
        // popover it was asked in may already have dismissed itself.
        if needsAttention || pendingConfirmation != nil { return .attention }
        if isPaused { return .paused }
        switch monitoringState {
        case .monitoring, .starting: return .listening
        case .stopped: return .paused
        case .failed: return .attention
        }
    }

    /// Cleared when the user opens the popover, which is the moment they have
    /// actually seen it.
    @Published private(set) var needsAttention = false

    func acknowledgeAttention() {
        needsAttention = false
    }

    /// True from the first unsuppressed crackle signal until a repair settles
    /// it or the detection window lapses with nothing further. Drives the
    /// menu-bar mark's red "on the case" state, so the user hearing the fault
    /// can see that Fennec hears it too.
    @Published private(set) var isCrackleWatchActive = false
    private var crackleWatchTimer: Timer?

    private func noteCrackleSignal() {
        isCrackleWatchActive = true
        crackleWatchTimer?.invalidate()
        // Linger one window past the last signal: exactly how long a fresh
        // signal could still combine with this one into a detection.
        let linger = settings.sensitivity.window + 2
        crackleWatchTimer = Timer.scheduledTimer(withTimeInterval: linger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearCrackleWatch()
            }
        }
    }

    private func clearCrackleWatch() {
        crackleWatchTimer?.invalidate()
        crackleWatchTimer = nil
        isCrackleWatchActive = false
    }

    // MARK: Standing down

    /// Set when three automatic repairs in twenty minutes did not hold. The
    /// restart is not the cure on this machine, and trying a fourth time just
    /// silences the audio again.
    @Published private(set) var standDown: RepairGovernor.StandDown?

    var isStandingDown: Bool { standDown?.isActive(at: Date()) ?? false }

    /// Clears the stand-down early. The user has looked at the reason and
    /// decided anyway, which is their call to make.
    func clearStandDown() {
        guard standDown != nil else { return }
        standDown = nil
        announcedStandDownUntil = nil
        record(.init(kind: .resumed, summary: "Stand-down cleared; automatic repair is armed again."))
    }

    private func refreshStandDown() {
        let current = RepairGovernor.standDown(records: repairHistory.records)
        if current != standDown {
            standDown = current
        }
    }

    // MARK: Pause

    @Published private(set) var pauseState: PauseState = .running

    var isPaused: Bool { pauseState.isPaused() }

    /// "Paused · resumes in 42 min", or `nil` while running.
    var pauseStatusText: String? { pauseState.statusText() }

    func pause(_ option: PauseSchedule.Option) {
        applyPause(.make(for: option, from: Date()))
        if let episodeID = promptedRepair?.episodeID {
            dismissDetectedRepairPrompt(episodeID: episodeID)
        }
        record(.init(
            kind: .paused,
            summary: "Automatic repair paused \(option.title.lowercased()).",
            details: ["option": option.rawValue]
        ))
    }

    func resume() {
        guard isPaused else { return }
        applyPause(.running)
        record(.init(kind: .resumed, summary: "Automatic repair resumed."))
    }

    private func applyPause(_ state: PauseState) {
        settings.pauseState = state
        pauseState = state
        schedulePauseExpiry()
    }

    /// Refreshes the countdown text and resumes on its own when the window
    /// closes. A pause that outlives its own expiry is the failure mode that
    /// makes people distrust the feature.
    private func schedulePauseExpiry() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard pauseState.isPaused(), !pauseState.isIndefinite else { return }

        pauseTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.pauseState.isPaused() else {
                    self.applyPause(.running)
                    self.record(.init(
                        kind: .resumed,
                        summary: "Pause expired; Fennec is watching \(self.currentDevice.name) again."
                    ))
                    self.notificationController.postResumed(device: self.currentDevice.name)
                    return
                }
                // Nudge the published value so the countdown re-renders.
                self.pauseState = self.settings.pauseState
            }
        }
    }

    /// The user finished or dismissed the first-run window.
    func completeFirstRun() {
        settings.hasCompletedFirstRun = true
    }

    /// Reopens first run on demand: the disclosure it carries is the answer
    /// to "what can this thing actually do", and that question does not stop
    /// being asked after day one.
    func showWelcomeWindow() {
        if !WindowPresenter.shared.isOpen(WindowPresenter.ID.welcome),
           !isRepairing, !isPreparingRepair {
            hasCompletedOnboardingRepair = false
            onboardingFoxRequestCount = 0
            onboardingFoxStarted = false
            if manualFoxBurstID == nil { WindowPresenter.shared.resetOnboardingFox() }
        }
        WindowPresenter.shared.showWelcome(model: self)
    }

    /// The privilege panel: what Fennec can do, what is running as root right
    /// now, how to verify the build, and how to remove all of it.
    func showAboutWindow() {
        WindowPresenter.shared.showAbout(model: self)
    }

    var installLocation: InstallLocation { InstallLocation.current() }

    var statusDetail: String {
        if isPaused {
            // The device card must not claim to be watching while the user
            // has explicitly told Fennec not to act.
            return "Repair responses are paused. Fennec is still counting signals on \(currentDevice.name)."
        }
        switch monitoringState {
        case .starting:
            return "Getting ready to listen…"
        case .monitoring:
            return "Watching \(currentDevice.name) for missed real-time deadlines."
        case .stopped:
            return "Crackle detection is stopped."
        case .failed(let message):
            return message
        }
    }

    /// The single question the UI is currently asking, if any. One property
    /// so the popover and Settings render the same card.
    var pendingConfirmation: PendingConfirmation? {
        if let administratorRepairRequest { return .administrator(administratorRepairRequest) }
        if let manualRepairWarning { return .audioInUse(manualRepairWarning) }
        return nil
    }

    func confirm(_ confirmation: PendingConfirmation) {
        switch confirmation {
        case .audioInUse: confirmManualRepair()
        case .administrator: confirmAdministratorRepair()
        }
    }

    func cancel(_ confirmation: PendingConfirmation) {
        switch confirmation {
        case .audioInUse: cancelManualRepair()
        case .administrator: cancelAdministratorRepair()
        }
    }

    /// True when Fennec can repair on its own without asking for anything.
    var isArmed: Bool {
        settings.repairMode == .automatic && helperManager.state.isReachable
    }

    // MARK: Setup readiness

    var setupSteps: [SetupStep] {
        SetupChecklist.steps(
            helper: helperManager.state,
            loginItem: loginItemManager.state,
            notificationsAuthorized: notificationController.isAuthorized,
            repairMode: settings.repairMode,
            location: installLocation
        )
    }

    var remainingSetupSteps: [SetupStep] {
        SetupChecklist.remaining(
            helper: helperManager.state,
            loginItem: loginItemManager.state,
            notificationsAuthorized: notificationController.isAuthorized,
            repairMode: settings.repairMode,
            location: installLocation
        )
    }

    var setupSummary: String {
        SetupChecklist.summary(
            helper: helperManager.state,
            loginItem: loginItemManager.state,
            notificationsAuthorized: notificationController.isAuthorized,
            repairMode: settings.repairMode,
            location: installLocation
        )
    }

    /// Copies the bundle to Applications and relaunches from there. The old
    /// registration problem this solves is documented on `InstallLocation`.
    func moveToApplications() {
        installError = nil
        do {
            let destination = try InstallLocation.moveToApplications()
            let configuration = NSWorkspace.OpenConfiguration()
            // The same bundle id is already running (this process), so the
            // relaunch must be allowed to be a second instance for the
            // moment the two overlap.
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if error == nil {
                        NSApp.terminate(nil)
                    } else {
                        self.installError = "Fennec was copied to Applications but could not relaunch itself. "
                            + "Quit this copy and open the one in Applications."
                    }
                }
            }
        } catch {
            installError = "Could not copy Fennec to Applications: \(error.localizedDescription)"
        }
    }

    @Published var installError: String?

    /// Somewhere for `pendingConfirmation` to be rendered.
    ///
    /// The popover is a panel that dismisses the moment it loses key, and the
    /// "microphone is live" card is raised at exactly the moment the user is
    /// about to click over to the call app. The Repair Now notification action
    /// has no window at all. Without a host the user's click produced nothing.
    private func ensureConfirmationHasAHost() {
        guard pendingConfirmation != nil else { return }
        guard !WindowPresenter.shared.hasVisibleWindow else { return }
        WindowPresenter.shared.showSettings(model: self)
    }

    /// The single entry point for every setup button in the app, so the
    /// popover, Settings, and the first-run window cannot disagree about what
    /// "Turn On" means.
    func performSetupAction(for step: SetupStep) {
        switch step.kind {
        case .install:
            // The button says Move to Applications, so it moves, for a
            // development build too: the step is optional there, and a
            // developer clicking it anyway has decided.
            if case .applications = installLocation { break }
            moveToApplications()
        case .helper:
            if helperManager.state.isEnabled && !helperManager.state.isReachable {
                // "Recheck" used to re-ping a registration that could not
                // answer and call it a day. The button now does what the user
                // would be told to do by hand: rebuild the registration.
                Task { _ = await healSilentHelper(userInitiated: true) }
            } else {
                helperManager.register()
            }
        case .helperApproval:
            helperManager.openApprovalSettings()
        case .loginItem:
            if loginItemManager.state.requiresApproval {
                loginItemManager.openSettings()
            } else {
                loginItemManager.enable()
            }
        case .notifications:
            // macOS gives an app exactly one authorization prompt, ever. It
            // used to be spent by `init`, one run-loop turn ahead of the
            // welcome window, so a user who declined in the first seconds
            // could never be asked again. Now the button spends it.
            if notificationController.authorizationChecked && !notificationController.isAuthorized {
                notificationController.openSystemSettings()
            } else {
                notificationController.requestAuthorization()
            }
        }
    }

    // MARK: Monitoring lifecycle

    func startMonitoring() {
        monitoringState = .starting
        // The log watcher is independent of the listener graph on purpose:
        // whichever of the two witnesses still works should keep working.
        logMonitor.start()
        do {
            try monitor.start()
            guard monitor.isAttached else {
                throw CoreAudioMonitorError.allocationFailed
            }
            monitoringState = .monitoring
            needsAttention = false
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
        logMonitor.stop()
        monitoringState = .stopped
    }

    func restartMonitoring() {
        monitor.stop()
        logMonitor.stop()
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

    /// Extends the suppression window. Never shortens it: two events that
    /// overlap should leave the longer of the two in force.
    private func beQuiet(for event: SystemEvent, log: Bool = true) {
        let until = Date().addingTimeInterval(event.quietSeconds)
        guard until > suppressSignalsUntil else { return }
        suppressSignalsUntil = until
        detectionEngine.reset()
        if log {
            record(.init(
                kind: .suppressed,
                summary: event.reason,
                details: ["event": event.rawValue, "seconds": String(Int(event.quietSeconds))]
            ))
        }
    }

    // MARK: User-initiated repair

    /// Preview uses the same bounded animation queue as a manual repair,
    /// without entering any audio or privileged repair path.
    func requestPreviewFox() {
        if previewFoxBurstID != nil {
            guard previewFoxRequestCount < RepairFoxBurst.maximumTotal else { return }
            if WindowPresenter.shared.queueOnboardingFox() {
                previewFoxRequestCount += 1
            }
            return
        }
        guard !isRepairing, !isPreparingRepair, manualFoxBurstID == nil,
              onboardingFoxRequestCount == 0,
              WindowPresenter.shared.canShowRepairFoxBurst else { return }
        let id = UUID()
        guard WindowPresenter.shared.startManualFoxBurst(for: id) else { return }
        previewFoxBurstID = id
        previewFoxRequestCount = 1
    }

    /// Every Repair Audio control takes this route. The first click retains
    /// the normal safety and privilege checks; while its fox burst is alive,
    /// later clicks only request another bounded crossing.
    func requestRepairButton(for episodeID: UUID? = nil) {
        guard !updaterInstallationPending else { return }
        endPreviewFoxBurst()
        if manualFoxBurstID != nil {
            guard manualFoxRequestCount < RepairFoxBurst.maximumTotal else { return }
            if !manualFoxBurstStarted || WindowPresenter.shared.queueOnboardingFox() {
                manualFoxRequestCount += 1
            }
            return
        }
        if let episodeID, !faultEpisodes.isCurrent(episodeID) { return }
        guard !isRepairing, !isPreparingRepair else { return }
        if onboardingFoxRequestCount > 0 {
            WindowPresenter.shared.resetOnboardingFox()
            onboardingFoxRequestCount = 0
            onboardingFoxStarted = false
        }
        if WindowPresenter.shared.canShowRepairFoxBurst {
            manualFoxBurstID = UUID()
            manualFoxRequestCount = 1
            manualFoxBurstStarted = false
        }
        requestManualRepair(for: episodeID)
    }

    func requestManualRepair(for episodeID: UUID? = nil, approvedByNotification: Bool = false) {
        guard !updaterInstallationPending, !isRepairing, !isPreparingRepair else { return }
        if let episodeID {
            guard faultEpisodes.isCurrent(episodeID) else { return }
        }
        pendingManualEpisodeID = episodeID
        pendingManualDecision = episodeID.flatMap { decisionByEpisode[$0] }
        pendingManualDeviceUID = episodeID.flatMap { deviceUIDByEpisode[$0] }
            ?? (episodeID == nil ? nil : currentDevice.uid)
        isPreparingRepair = true
        throttleNotice = nil
        Task {
            defer { isPreparingRepair = false }
            let protectMicrophone = settings.protectMicrophone
            let protectApps = settings.protectCommunicationApps
            let report = await Task.detached(priority: .utility) { [safetyChecker] in
                safetyChecker.evaluate(
                    protectMicrophone: protectMicrophone,
                    protectCommunicationApps: protectApps
                )
            }.value

            guard pendingManualEpisodeIsValid() else { return }
            if report.canAutoRepair {
                await beginManualRepair(
                    decision: pendingManualDecision,
                    approvedByNotification: approvedByNotification
                )
            } else {
                manualRepairWarning = ManualRepairWarning(
                    message: report.blockers.joined(separator: "\n\n")
                        + "\n\nRepairing stops your sound for a moment."
                )
                ensureConfirmationHasAHost()
            }
        }
    }

    func confirmManualRepair() {
        manualRepairWarning = nil
        guard pendingManualEpisodeIsValid() else { return }
        Task { await beginManualRepair(decision: pendingManualDecision) }
    }

    func cancelManualRepair() {
        manualRepairWarning = nil
        if let episodeID = pendingManualEpisodeID {
            dismissDetectedRepairPrompt(episodeID: episodeID)
        }
        pendingManualEpisodeID = nil
        pendingManualDecision = nil
        pendingManualDeviceUID = nil
        rehearsalRequested = false
        resetPendingOnboardingFox()
        endManualFoxBurst()
    }

    func requestPromptedRepair(_ prompt: DetectedRepairPrompt) {
        guard promptedRepair?.id == prompt.id else { return }
        if manualFoxBurstID != nil {
            requestRepairButton()
            return
        }
        guard faultEpisodes.mayPrompt(for: prompt.episodeID) else { return }
        requestRepairButton(for: prompt.episodeID)
    }

    private func pendingManualEpisodeIsValid() -> Bool {
        guard let episodeID = pendingManualEpisodeID else { return true }
        guard faultEpisodes.isCurrent(episodeID),
              let expectedDeviceUID = pendingManualDeviceUID,
              currentDevice.uid == expectedDeviceUID else {
            manualRepairWarning = nil
            administratorRepairRequest = nil
            pendingManualEpisodeID = nil
            pendingManualDecision = nil
            pendingManualDeviceUID = nil
            resetPendingOnboardingFox()
            endManualFoxBurst()
            record(.init(kind: .repairSkipped, summary: "The audio output or crackling episode changed while the repair was being prepared."))
            return false
        }
        return true
    }

    func dismissDetectedRepairPrompt(episodeID: UUID, closeWindow: Bool = true) {
        faultEpisodes.suppress(episodeID)
        guard promptedRepair?.episodeID == episodeID else { return }
        promptedRepair = nil
        if closeWindow { WindowPresenter.shared.closeRepairPrompt() }
    }

    private func notifyDetectedRepairRequest(
        decision: DetectionDecision,
        device: AudioDeviceSnapshot,
        episodeID: UUID
    ) {
        guard currentDevice.uid == device.uid, faultEpisodes.mayPrompt(for: episodeID) else { return }
        guard notifiedRepairEpisodeID != episodeID else { return }
        guard notificationController.isAuthorized else {
            recordSkipped("A repair decision needs notifications, but Fennec notifications are off.")
            return
        }
        notifiedRepairEpisodeID = episodeID
        notificationController.postRepairRequest(reason: decision.plainReason, episodeID: episodeID)
    }

    private func handleSuccessfulLogCoverage(from: Date, through: Date, eventDates: [Date]) {
        for date in eventDates {
            _ = faultEpisodes.noteSignal(at: date)
        }
        let lastPlaybackSample = [recentAudioActivity.last, pendingActivity.last].compactMap { $0 }.max()
        let recentPlayback = lastPlaybackSample.map {
            through.timeIntervalSince($0) <= OverloadLogSchedule.runningGrace
        } ?? false
        guard recentPlayback,
              let endedEpisode = faultEpisodes.observeSuccessfulCoverage(from: from, through: through) else { return }
        decisionByEpisode.removeValue(forKey: endedEpisode)
        deviceUIDByEpisode.removeValue(forKey: endedEpisode)
        if notifiedRepairEpisodeID == endedEpisode { notifiedRepairEpisodeID = nil }
        if promptedRepair?.episodeID == endedEpisode {
            promptedRepair = nil
            WindowPresenter.shared.closeRepairPrompt()
        }
    }

    /// The one place that decides *which* privileged path a manual repair
    /// takes. If the helper can do it, it does: silently and without a
    /// password. If it cannot, Fennec asks before summoning an admin prompt.
    /// The first-run window's own test repair.
    ///
    /// It is deliberately not counted as an incident: the days-without-
    /// incident sign justifies counting manual repairs because "the user only
    /// pressed the button because something was wrong", which is precisely
    /// untrue of the one repair the product asks them to run.
    func requestRehearsalRepair() {
        guard !updaterInstallationPending else { return }
        endPreviewFoxBurst()
        if manualFoxBurstID != nil {
            requestRepairButton()
            return
        }
        if hasCompletedOnboardingRepair || onboardingFoxRequestCount > 0 {
            guard onboardingFoxRequestCount < RepairFoxBurst.maximumTotal else { return }
            if !onboardingFoxStarted || WindowPresenter.shared.queueOnboardingFox() {
                onboardingFoxRequestCount += 1
            }
            return
        }
        guard !isRepairing, !isPreparingRepair else { return }
        if WindowPresenter.shared.canShowRepairFoxBurst {
            onboardingFoxRequestCount = 1
            onboardingFoxStarted = false
        }
        rehearsalRequested = true
        requestManualRepair()
    }

    private var isRehearsal: Bool { rehearsalRequested }

    /// One attempt to bring an enabled-but-silent helper back without the
    /// user: rebuild the registration from the running bundle, no password.
    /// Every attempt and its outcome goes in the record: a daemon
    /// registration being rewritten is exactly the kind of thing the event
    /// log exists to admit to. Returns whether the helper answers now.
    private func healSilentHelper(userInitiated: Bool) async -> Bool {
        let state = helperManager.state
        guard helperHealPolicy.shouldAttempt(
            enabled: state.isEnabled,
            reachable: state.isReachable,
            userInitiated: userInitiated
        ) else { return state.isReachable }

        record(.init(
            kind: .helper,
            summary: "The repair helper is enabled but not answering; rebuilding its registration."
        ))
        let healed = await helperManager.rebuildRegistration()
        if healed {
            record(.init(kind: .helper, summary: "The repair helper is answering again."))
        } else if case .awaitingApproval = helperManager.state {
            record(.init(
                kind: .helper,
                summary: "The rebuilt registration needs approval under Login Items & Extensions."
            ))
        } else {
            record(.init(
                kind: .helper,
                summary: "Rebuilding the registration did not bring the helper back."
            ))
        }
        return healed
    }

    private func beginManualRepair(
        decision: DetectionDecision?,
        approvedByNotification: Bool = false
    ) async {
        guard !updaterInstallationPending, pendingManualEpisodeIsValid() else { return }
        let trigger: RepairRecord.Trigger = isRehearsal ? .rehearsal : .manual
        if helperManager.state.isReachable {
            await performRepair(trigger: trigger, decision: decision, viaAdministratorPrompt: false)
            return
        }
        // Before asking for a password, try the fix that needs none.
        let healed = await healSilentHelper(userInitiated: true)
        guard pendingManualEpisodeIsValid() else { return }
        if healed {
            await performRepair(trigger: trigger, decision: decision, viaAdministratorPrompt: false)
            return
        }
        if approvedByNotification {
            await performRepair(trigger: trigger, decision: decision, viaAdministratorPrompt: true)
            return
        }
        let reason: String
        switch helperManager.state {
        case .enabled:
            reason = "Fennec's repair helper is installed but is not answering (rebuilding its "
                + "registration did not bring it back), so it cannot fix crackling on its own."
        case .awaitingApproval:
            reason = "macOS is waiting for you to allow Fennec's repair helper under "
                + "Login Items & Extensions, so it cannot fix crackling on its own."
        case .notConfigured, .unavailable:
            reason = "Fennec's repair helper is not enabled, so it cannot fix crackling on its own."
        }
        administratorRepairRequest = AdministratorRepairRequest(
            reason: reason,
            command: PrivilegedPromptRepair.command
        )
        ensureConfirmationHasAHost()
    }

    func confirmAdministratorRepair() {
        administratorRepairRequest = nil
        guard pendingManualEpisodeIsValid() else { return }
        let trigger: RepairRecord.Trigger = isRehearsal ? .rehearsal : .manual
        Task { await performRepair(trigger: trigger, decision: pendingManualDecision, viaAdministratorPrompt: true) }
    }

    func cancelAdministratorRepair() {
        administratorRepairRequest = nil
        if let episodeID = pendingManualEpisodeID {
            dismissDetectedRepairPrompt(episodeID: episodeID)
        }
        pendingManualEpisodeID = nil
        pendingManualDecision = nil
        pendingManualDeviceUID = nil
        rehearsalRequested = false
        resetPendingOnboardingFox()
        endManualFoxBurst()
        record(.init(kind: .repairSkipped, summary: "Administrator repair was cancelled."))
    }

    /// Called only after the user has pressed the final Install & Relaunch
    /// button. New repairs are held while an active attempt finishes, then a
    /// previously registered helper is unregistered so Sparkle can replace
    /// the app bundle without leaving launchd bound to a stale executable.
    func prepareForUpdateInstall() async -> Bool {
        guard !updaterInstallationPending else { return false }
        let preparationID = UUID()
        updatePreparationID = preparationID
        updatePreparationCancelled = false
        updaterInstallationPending = true

        while isRepairing || isPreparingRepair {
            if updatePreparationID != preparationID || updatePreparationCancelled {
                return await cancelUpdatePreparation(helperWasRegistered: false)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if updatePreparationID != preparationID || updatePreparationCancelled {
            return await cancelUpdatePreparation(helperWasRegistered: false)
        }

        let helperWasRegistered = helperManager.isRegistered
        if helperWasRegistered {
            UserDefaults.standard.set(true, forKey: FennecUpdater.helperWasRegisteredKey)
            let unregistered = await helperManager.unregisterForUpdate()
            if updatePreparationID != preparationID || updatePreparationCancelled {
                return await cancelUpdatePreparation(helperWasRegistered: unregistered)
            }
            guard unregistered else {
                UserDefaults.standard.removeObject(forKey: FennecUpdater.helperWasRegisteredKey)
                updaterInstallationPending = false
                updatePreparationID = nil
                return false
            }
        } else {
            UserDefaults.standard.removeObject(forKey: FennecUpdater.helperWasRegisteredKey)
        }
        updatePreparationID = nil
        return true
    }

    private func cancelUpdatePreparation(helperWasRegistered: Bool) async -> Bool {
        if helperWasRegistered {
            let restored = await helperManager.restoreRegistrationAfterUpdate()
            if !restored { settings.repairMode = .askFirst }
        }
        UserDefaults.standard.removeObject(forKey: FennecUpdater.helperWasRegisteredKey)
        updaterInstallationPending = false
        updatePreparationID = nil
        updatePreparationCancelled = false
        return false
    }

    /// A canceled or failed install leaves this copy running. Put back only
    /// a helper that was registered before the user started the update.
    func cancelUpdateInstallation() {
        if updatePreparationID != nil {
            updatePreparationCancelled = true
            return
        }
        let helperWasRegistered = UserDefaults.standard.bool(forKey: FennecUpdater.helperWasRegisteredKey)
        guard updaterInstallationPending || helperWasRegistered else { return }
        Task { [weak self] in
            guard let self else { return }
            if helperWasRegistered {
                let restored = await helperManager.restoreRegistrationAfterUpdate()
                if !restored { settings.repairMode = .askFirst }
                UserDefaults.standard.removeObject(forKey: FennecUpdater.helperWasRegisteredKey)
            }
            updaterInstallationPending = false
        }
    }

    func openEventLog() {
        NSWorkspace.shared.activateFileViewerSelecting([eventLogger.logURL])
    }

    @discardableResult
    func copyRecentEvents() -> Bool {
        guard !recentActivity.isEmpty else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = recentActivity.reversed().compactMap { record -> String? in
            guard let data = try? encoder.encode(record) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard !lines.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// The app's bundle has already moved to the Trash when this runs.
    /// AppKit can leave its last sheet on screen without ending that process,
    /// so give normal termination a chance and then guarantee the uninstall
    /// does not strand a live copy outside Applications. A repair gets longer
    /// than AppDelegate's 12-second quit grace before the fallback fires.
    func quitAfterSuccessfulUninstall() {
        let delay: TimeInterval = isRepairing || isPreparingRepair ? 15 : 2
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            Darwin._exit(EXIT_SUCCESS)
        }
        quit()
    }

    // MARK: Signal handling

    private func handle(_ batch: AudioSignalBatch) {
        let previousDeviceUID = currentDevice.uid
        currentDevice = batch.device

        if !previousDeviceUID.isEmpty, previousDeviceUID != batch.device.uid {
            notifiedRepairEpisodeID = nil
            if let episodeID = promptedRepair?.episodeID {
                dismissDetectedRepairPrompt(episodeID: episodeID)
            }
            faultEpisodes.invalidateForOutputChange()
            decisionByEpisode.removeAll()
            deviceUIDByEpisode.removeAll()
        }

        if batch.serviceRestarts > 0 {
            // Every AudioObjectID from before the restart is invalid,
            // including the log monitor's cached gate device.
            logMonitor.noteOutputDeviceMayHaveChanged()
            detectionEngine.reset()
            suppressSignalsUntil = max(suppressSignalsUntil, batch.date.addingTimeInterval(12))
            record(.init(
                kind: .serviceRestarted,
                summary: "Core Audio restarted; monitoring listeners were rebuilt.",
                details: ["count": String(batch.serviceRestarts)],
                date: batch.date
            ))
        }

        if batch.defaultOutputChanges > 0 || batch.deviceStateChanges > 0 {
            logMonitor.noteOutputDeviceMayHaveChanged()
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
            recentOverloadDates.append(
                contentsOf: batch.overloadDates
                    ?? Array(repeating: batch.date, count: Int(batch.overloads))
            )
            pruneRecentDates()
            record(.init(
                kind: .signal,
                summary: "Core Audio processor overload signal received.",
                details: [
                    "count": String(batch.overloads),
                    "device": batch.device.name,
                    "sampleRate": String(format: "%.0f", batch.device.sampleRate),
                    "source": batch.source.title
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

        // A real failure signal, past every suppression window: the menu-bar
        // mark goes red now, threshold met or not, because this is the moment
        // the user is actually hearing something wrong.
        noteCrackleSignal()

        var episodeID: UUID?
        if batch.overloads > 0 {
            for date in batch.overloadDates ?? Array(repeating: batch.date, count: Int(batch.overloads)) {
                episodeID = faultEpisodes.noteSignal(at: date)
            }
        }
        if batch.abnormalStops > 0 {
            episodeID = faultEpisodes.noteSignal(at: batch.date)
        }
        if let episodeID {
            deviceUIDByEpisode[episodeID] = batch.device.uid
        }

        guard let decision = detectionEngine.ingest(batch, sensitivity: settings.sensitivity) else { return }
        guard let episodeID else { return }

        // A fresh detection inside the verification window is the fault
        // coming back, which is the one thing that decides whether the last
        // repair actually worked.
        if let verifyingRepairID {
            failVerification(verifyingRepairID)
        }

        detectionCount += 1
        decisionByEpisode[episodeID] = decision
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
            await respondToDetection(decision, device: batch.device, episodeID: episodeID)
        }
    }

    /// Everything between "Fennec is sure the audio is broken" and "Fennec
    /// restarts Core Audio". Every early return is a refusal the user is
    /// entitled to see, so each one records a reason.
    private func respondToDetection(
        _ decision: DetectionDecision,
        device: AudioDeviceSnapshot,
        episodeID: UUID
    ) async {
        guard !updaterInstallationPending else {
            recordSkipped("An app update is preparing to install.")
            return
        }
        if isPaused {
            // Deliberately silent and deliberately above every other gate: the
            // user asked for quiet, and a banner explaining why Fennec is quiet
            // would defeat the point.
            recordSkipped(pauseStatusText ?? "Fennec is paused.")
            return
        }

        refreshStandDown()
        if let standDown, standDown.isActive(at: Date()) {
            recordSkipped(standDown.reason)
            announceStandDownIfNeeded(standDown)
            return
        }

        guard !isRepairing else {
            recordSkipped("A repair is already running.")
            return
        }

        if settings.skipBluetooth && device.transport.isBluetooth {
            let blocker = "Automatic repair is set to skip Bluetooth outputs."
            recordSkipped(blocker)
            notifyUnrepaired(decision, blocker: blocker, episodeID: episodeID)
            return
        }

        // The cooldown sits above every remaining gate on purpose. It used to
        // sit below the helper check and key off the last *successful* repair,
        // which meant a machine that had never repaired had no cooldown at
        // all, so a fresh install, helper not yet enabled, answered every
        // signal burst with another banner.
        if let lastRepairAttemptDate {
            let elapsed = Date().timeIntervalSince(lastRepairAttemptDate)
            if elapsed < settings.cooldownSeconds {
                let remaining = Int(ceil(settings.cooldownSeconds - elapsed))
                // Deliberately silent: the user was told about the attempt
                // that started this cooldown, seconds ago.
                recordSkipped("Repair cooldown is active for another \(remaining) seconds.")
                return
            }
        }

        guard LoginSession.isOnConsole() else {
            // A repair is system-wide but the safety checks only see this
            // user's processes. Acting from a background session could cut
            // someone else's call and report the machine was clear.
            let blocker = "Fennec is not the session at the keyboard."
            recordSkipped(blocker)
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
            notifyUnrepaired(decision, blocker: blocker, episodeID: episodeID)
            return
        }

        guard settings.protectMicrophone == protectMicrophone,
              settings.protectCommunicationApps == protectApps else {
            recordSkipped("Safety settings changed while Fennec was checking audio use.")
            return
        }

        guard currentDevice.uid == device.uid else {
            recordSkipped("The audio output changed while Fennec was checking it.")
            return
        }

        guard faultEpisodes.mayPrompt(for: episodeID) else {
            recordSkipped("This crackling episode has already been answered.")
            return
        }

        if settings.repairMode == .askFirst {
            notifyDetectedRepairRequest(decision: decision, device: device, episodeID: episodeID)
            return
        }

        let helperNeedsRecovery = helperManager.state.isEnabled && !helperManager.state.isReachable
        if helperNeedsRecovery {
            // The one blocker Fennec can remove by itself: the helper is
            // approved but silent, and a rebuilt registration is often the
            // difference between repairing now and posting a banner about
            // why it could not.
            _ = await healSilentHelper(userInitiated: false)
        }

        // A helper rebuild can take several seconds. The person may have
        // paused Fennec, changed repair mode or output, or left the console
        // while it was suspended. None of the earlier gates remain authoritative.
        guard !updaterInstallationPending else {
            recordSkipped("An app update is preparing to install.")
            return
        }
        guard !isPaused else {
            recordSkipped(pauseStatusText ?? "Fennec is paused.")
            return
        }
        guard currentDevice.uid == device.uid else {
            recordSkipped("The audio output changed while Fennec was checking it.")
            return
        }
        guard faultEpisodes.mayPrompt(for: episodeID) else {
            recordSkipped("This crackling episode has already been answered.")
            return
        }
        guard LoginSession.isOnConsole() else {
            recordSkipped("Fennec is not the session at the keyboard.")
            return
        }
        if settings.repairMode == .askFirst {
            notifyDetectedRepairRequest(decision: decision, device: device, episodeID: episodeID)
            return
        }

        if helperNeedsRecovery {
            // A call or recording can start while the helper is being rebuilt.
            // Read the current preferences and audio processes before committing.
            let protectMicrophone = settings.protectMicrophone
            let protectApps = settings.protectCommunicationApps
            let currentReport = await Task.detached(priority: .utility) { [safetyChecker] in
                safetyChecker.evaluate(
                    protectMicrophone: protectMicrophone,
                    protectCommunicationApps: protectApps
                )
            }.value
            guard currentReport.canAutoRepair else {
                let blocker = currentReport.blockers.joined(separator: " ")
                recordSkipped(blocker)
                notifyUnrepaired(decision, blocker: blocker, episodeID: episodeID)
                return
            }
            guard settings.protectMicrophone == protectMicrophone,
                  settings.protectCommunicationApps == protectApps else {
                recordSkipped("Safety settings changed while Fennec was checking audio use.")
                return
            }
        }

        // The second safety scan also suspends this task. Recheck the state
        // before offering a prompt if the helper is still unavailable.
        guard !updaterInstallationPending, !isPaused,
              currentDevice.uid == device.uid,
              faultEpisodes.mayPrompt(for: episodeID),
              LoginSession.isOnConsole() else {
            recordSkipped("The repair conditions changed while Fennec was checking the helper.")
            return
        }
        if settings.repairMode == .askFirst {
            notifyDetectedRepairRequest(decision: decision, device: device, episodeID: episodeID)
            return
        }
        if settings.skipBluetooth && device.transport.isBluetooth {
            let blocker = "Automatic repair is set to skip Bluetooth outputs."
            recordSkipped(blocker)
            notifyUnrepaired(decision, blocker: blocker, episodeID: episodeID)
            return
        }

        guard helperManager.state.isReachable else {
            // The saved preference remains automatic. A repair that needs an
            // administrator password still requires a notification click.
            recordSkipped(RepairCopy.helperBlocker(for: helperManager.state))
            notifyDetectedRepairRequest(decision: decision, device: device, episodeID: episodeID)
            return
        }

        await performRepair(
            trigger: .automatic,
            decision: decision,
            viaAdministratorPrompt: false,
            automaticDevice: device,
            automaticEpisodeID: episodeID,
            automaticSafetyPreferences: (settings.protectMicrophone, settings.protectCommunicationApps)
        )
    }

    // MARK: The repair itself

    private func performRepair(
        trigger: RepairRecord.Trigger,
        decision: DetectionDecision?,
        viaAdministratorPrompt: Bool,
        automaticDevice: AudioDeviceSnapshot? = nil,
        automaticEpisodeID: UUID? = nil,
        automaticSafetyPreferences: (Bool, Bool)? = nil
    ) async {
        guard !updaterInstallationPending, !isRepairing else { return }
        if trigger == .automatic {
            guard let automaticDevice, let automaticEpisodeID, let decision else { return }
            // The call to this async method is another suspension point. These
            // checks and isRepairing's transition now occur on one actor turn.
            guard !isPaused else {
                recordSkipped(pauseStatusText ?? "Fennec is paused.")
                return
            }
            guard currentDevice.uid == automaticDevice.uid else {
                recordSkipped("The audio output changed while Fennec was checking it.")
                return
            }
            guard faultEpisodes.mayPrompt(for: automaticEpisodeID) else {
                recordSkipped("This crackling episode has already been answered.")
                return
            }
            guard LoginSession.isOnConsole() else {
                recordSkipped("Fennec is not the session at the keyboard.")
                return
            }
            guard let automaticSafetyPreferences,
                  settings.protectMicrophone == automaticSafetyPreferences.0,
                  settings.protectCommunicationApps == automaticSafetyPreferences.1 else {
                recordSkipped("Safety settings changed while Fennec was checking audio use.")
                return
            }
            if settings.repairMode == .askFirst {
                notifyDetectedRepairRequest(
                    decision: decision, device: automaticDevice, episodeID: automaticEpisodeID
                )
                return
            }
            if settings.skipBluetooth && automaticDevice.transport.isBluetooth {
                let blocker = "Automatic repair is set to skip Bluetooth outputs."
                recordSkipped(blocker)
                notifyUnrepaired(decision, blocker: blocker, episodeID: automaticEpisodeID)
                return
            }
            refreshStandDown()
            if let standDown, standDown.isActive(at: Date()) {
                recordSkipped(standDown.reason)
                announceStandDownIfNeeded(standDown)
                return
            }
            if let lastRepairAttemptDate,
               Date().timeIntervalSince(lastRepairAttemptDate) < settings.cooldownSeconds {
                recordSkipped("Repair cooldown became active while Fennec was checking the helper.")
                return
            }
        }
        isRepairing = true
        // The heads-up is posted only when the final safety and consent gates
        // have passed, so a canceled automatic decision cannot promise repair.
        if trigger == .automatic && settings.notifyOnRepair {
            notificationController.postRepairStarting()
        }
        // The one onboarding test must not put automatic repair on cooldown.
        // Later onboarding clicks never reach this privileged path at all.
        if trigger != .rehearsal { lastRepairAttemptDate = Date() }
        detectionEngine.reset()
        suppressSignalsUntil = Date().addingTimeInterval(12)

        let device = currentDevice
        let automatic = trigger == .automatic
        record(.init(
            kind: .repairRequested,
            summary: automatic ? "Automatic Core Audio repair requested." : "Manual Core Audio repair requested."
        ))

        // The heads-up is posted only after the safety scan passes, directly
        // before this call, so Fennec never promises a repair it must retract.

        let foxAttemptID = trigger == .manual ? (manualFoxBurstID ?? UUID()) : UUID()
        var repairCompleted = false
        if !viaAdministratorPrompt {
            startRepairFox(trigger: trigger, attemptID: foxAttemptID)
        }
        // Measured across the privileged call only, excluding presentation.
        let started = Date()

        do {
            // Exactly one privileged path per attempt, chosen before the call.
            // The previous version fell through to an administrator prompt
            // whenever the helper threw, which meant a transient XPC hiccup
            // could raise a password dialog the user never asked for and
            // Fennec never explained.
            let message = viaAdministratorPrompt
                ? try await PrivilegedPromptRepair.restartCoreAudio()
                : try await helperManager.restartCoreAudio()
            let repairDuration = Date().timeIntervalSince(started)

            // The password API has no separate authorization callback. A
            // cancelled dialog must never launch a fox or queue one for later.
            // Once shown, success leaves the crossing free to finish.
            if viaAdministratorPrompt {
                startRepairFox(trigger: trigger, attemptID: foxAttemptID)
            }

            let repair = makeRecord(
                trigger: trigger,
                decision: decision,
                device: device,
                duration: repairDuration,
                succeeded: true,
                message: message
            )
            repairHistory.record(repair)
            repairCompleted = true
            lastRepairID = repair.id
            if trigger == .rehearsal { hasCompletedOnboardingRepair = true }
            lastError = nil
            detectionNotificationBudget.reset()
            record(.init(
                kind: .repairSucceeded,
                summary: message,
                details: repairDetails(repair)
            ))
            if settings.notifyOnRepair {
                notificationController.postRepairResult(repair)
            }
            beginVerification(of: repair)

            try? await Task.sleep(for: .milliseconds(1200))
            // Off the main actor on purpose. Rebuilding the listener graph is
            // ~25 synchronous HAL round-trips, scheduled 1.2 s after
            // coreaudiod was killed, inside the window where the replacement
            // is still publishing its object graph and HAL calls block. On the
            // main thread that is a beachball at the exact moment the user is
            // watching to see whether the repair worked.
            let restartError = await Task.detached(priority: .userInitiated) { [monitor] in
                do {
                    try monitor.restart()
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let restartError {
                monitoringState = .failed(restartError)
                lastError = restartError
                needsAttention = true
                record(.init(kind: .monitorError, summary: restartError))
            } else {
                monitoringState = .monitoring
                refreshCurrentDevice()
            }
        } catch is RepairCancelled {
            cancelRepairFox(trigger: trigger, attemptID: foxAttemptID)
            // The user pressed Cancel on the password prompt. That is a
            // decision, not a fault: no red receipt, no alarm, no attention
            // mark, and no reset of the days-without-incident sign.
            record(.init(kind: .repairSkipped, summary: "Administrator authorization was cancelled."))
            if let episodeID = pendingManualEpisodeID {
                dismissDetectedRepairPrompt(episodeID: episodeID)
            }
            clearCrackleWatch()
            isRepairing = false
            pendingManualEpisodeID = nil
            pendingManualDecision = nil
            pendingManualDeviceUID = nil
            rehearsalRequested = false
            return
        } catch let error as HelperCallError where error.isThrottled {
            cancelRepairFox(trigger: trigger, attemptID: foxAttemptID)
            // The helper enforces its own 20-second floor. "Did that help? Let
            // me press it again" is the most predictable thing a person does
            // after a manual repair, and reporting the rate limiter as a
            // failed repair told them their Mac was broken when it was not.
            lastError = nil
            record(.init(kind: .repairSkipped, summary: error.message))
            throttleNotice = error.message
            clearCrackleWatch()
            isRepairing = false
            pendingManualEpisodeID = nil
            pendingManualDecision = nil
            pendingManualDeviceUID = nil
            rehearsalRequested = false
            return
        } catch {
            cancelRepairFox(trigger: trigger, attemptID: foxAttemptID)
            let repair = makeRecord(
                trigger: trigger,
                decision: decision,
                device: device,
                duration: Date().timeIntervalSince(started),
                succeeded: false,
                message: error.localizedDescription
            )
            repairHistory.record(repair)
            lastRepairID = repair.id
            lastError = error.localizedDescription
            record(.init(
                kind: .repairFailed,
                summary: error.localizedDescription,
                details: repairDetails(repair)
            ))
            needsAttention = true
            // Always surfaced: a failed repair is the one case where the user
            // has to do something.
            notificationController.postRepairResult(repair)
            refreshStandDown()
            if let standDown { announceStandDownIfNeeded(standDown) }
        }

        rehearsalRequested = false
        // The waiting is over either way: success is announced as resolved,
        // and failure raises the attention mark, which takes the icon anyway.
        clearCrackleWatch()
        isRepairing = false
        if repairCompleted, let episodeID = pendingManualEpisodeID {
            promptedRepair = nil
            WindowPresenter.shared.closeRepairPrompt()
            faultEpisodes.suppress(episodeID)
        }
        if trigger != .automatic {
            pendingManualEpisodeID = nil
            pendingManualDecision = nil
            pendingManualDeviceUID = nil
        }
    }

    private func startRepairFox(trigger: RepairRecord.Trigger, attemptID: UUID) {
        if trigger == .rehearsal {
            if WindowPresenter.shared.startOnboardingFox(for: attemptID) {
                onboardingFoxStarted = true
                let pending = max(0, onboardingFoxRequestCount - 1)
                for _ in 0..<pending { _ = WindowPresenter.shared.queueOnboardingFox() }
                onboardingFoxRequestCount = max(1, onboardingFoxRequestCount)
            } else {
                onboardingFoxRequestCount = 0
                onboardingFoxStarted = false
            }
        } else if trigger == .manual, manualFoxBurstID == attemptID {
            if WindowPresenter.shared.startManualFoxBurst(for: attemptID) {
                manualFoxBurstStarted = true
                let pending = max(0, manualFoxRequestCount - 1)
                for _ in 0..<pending { _ = WindowPresenter.shared.queueOnboardingFox() }
            } else {
                endManualFoxBurst()
            }
        } else {
            WindowPresenter.shared.showRepairFox(for: attemptID)
        }
    }

    private func cancelRepairFox(trigger: RepairRecord.Trigger, attemptID: UUID) {
        if trigger == .rehearsal {
            WindowPresenter.shared.cancelOnboardingFox(for: attemptID)
            onboardingFoxRequestCount = 0
            onboardingFoxStarted = false
        } else if trigger == .manual, manualFoxBurstID == attemptID {
            endManualFoxBurst()
        } else {
            WindowPresenter.shared.cancelRepairFox(for: attemptID)
        }
    }

    private func resetPendingOnboardingFox() {
        guard rehearsalRequested else { return }
        onboardingFoxRequestCount = 0
        onboardingFoxStarted = false
    }

    private func endManualFoxBurst() {
        guard let id = manualFoxBurstID else { return }
        WindowPresenter.shared.cancelOnboardingFox(for: id)
        manualFoxBurstID = nil
        manualFoxBurstStarted = false
        manualFoxRequestCount = 0
    }

    private func endPreviewFoxBurst() {
        guard let id = previewFoxBurstID else { return }
        WindowPresenter.shared.cancelOnboardingFox(for: id)
        previewFoxBurstID = nil
        previewFoxRequestCount = 0
    }

    // MARK: Verification

    /// Starts the quiet window. Aviator gold is not spent here: the brand
    /// reserves it for a repair that *worked*, and at this instant the only
    /// established fact is that a new `coreaudiod` exists.
    private func beginVerification(of repair: RepairRecord) {
        verificationTimer?.invalidate()
        verifyingRepairID = repair.id

        verificationTimer = Timer.scheduledTimer(
            withTimeInterval: RepairGovernor.verificationWindow,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.verifyingRepairID else { return }
                self.verifyingRepairID = nil
                self.repairHistory.setOutcome(.held, for: id)
                self.record(.init(
                    kind: .repairHeld,
                    summary: "No further signals for \(Int(RepairGovernor.verificationWindow)) seconds. The repair held."
                ))
                self.refreshStandDown()
            }
        }
    }

    private func failVerification(_ id: UUID) {
        verificationTimer?.invalidate()
        verificationTimer = nil
        verifyingRepairID = nil
        repairHistory.setOutcome(.returned, for: id)

        if let repair = repairHistory.records.first(where: { $0.id == id }) {
            record(.init(
                kind: .repairReturned,
                summary: "The fault came back inside the verification window.",
                details: repairDetails(repair)
            ))
            if settings.notifyOnRepair {
                // Replaces the earlier banner in place rather than stacking a
                // contradiction underneath it.
                notificationController.postFaultReturned(repair)
            }
        }
        refreshStandDown()
        if let standDown { announceStandDownIfNeeded(standDown) }
    }

    private func announceStandDownIfNeeded(_ standDown: RepairGovernor.StandDown) {
        guard announcedStandDownUntil != standDown.until else { return }
        announcedStandDownUntil = standDown.until
        needsAttention = true
        record(.init(kind: .stoodDown, summary: standDown.reason))
        notificationController.postStandDown(reason: standDown.reason)
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
            trigger: trigger == .manual && isRehearsal ? .rehearsal : trigger,
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

    /// Errors from the monitor's own queue.
    ///
    /// The dangerous case is a failed listener rebuild after a Core Audio
    /// service restart, which is exactly what happens right after Fennec
    /// restarts `coreaudiod`. `rebuildListenersLocked()` removes every
    /// registration on the way out, so the monitor keeps its timer and loses
    /// its ears. This used to leave the popover showing a blue dot and the
    /// word "Listening" over an app that could no longer hear anything.
    /// Clean IO stops from the unified log: the playback-stall signature.
    /// `StallAdvisor` decides whether the pattern plus a starved machine adds
    /// up to something worth saying; the budget keeps it to one banner per
    /// half hour, and the graph gets every stop regardless.
    private func handleIOStops(_ stops: [Date]) {
        guard !stops.isEmpty else { return }
        recentStallDates.append(contentsOf: stops)
        pruneRecentDates()

        guard let advisory = StallAdvisor.assess(
            stopDates: recentStallDates,
            now: Date(),
            loadPerCore: SystemLoadSampler.loadPerCore(),
            memoryPressureLevel: SystemLoadSampler.memoryPressureLevel()
        ) else { return }
        guard stallNotificationBudget.allow() else { return }
        record(.init(
            kind: .advisory,
            summary: "Playback is stalling under system load. A Core Audio restart will not help.",
            details: [
                "stops": String(advisory.stopCount),
                "windowSeconds": String(Int(advisory.windowSeconds)),
                "loadPerCore": String(format: "%.2f", advisory.loadPerCore),
                "memoryPressure": advisory.memoryPressureLabel
            ]
        ))
        notificationController.postStallAdvisory(advisory)
    }

    /// Activity samples arrive once a second while audio plays, and every
    /// `@Published` mutation re-evaluates two live view graphs (the closed
    /// popover's and the menu-bar item's), which sampled at about two
    /// percent of a core for data nobody was looking at. Off screen, the
    /// samples pool in a plain array and publish once per pool; on screen,
    /// they publish per second, because that is when the ribbon's leading
    /// edge is being watched.
    private var pendingActivity: [Date] = []
    private var graphIsOnScreen = false
    private static let hiddenActivityFlushCount = 30

    private func ingestActivitySample(_ date: Date) {
        if graphIsOnScreen {
            recentAudioActivity.append(date)
            if recentAudioActivity.count % 30 == 0 {
                pruneRecentDates()
            }
        } else {
            pendingActivity.append(date)
            if pendingActivity.count >= Self.hiddenActivityFlushCount {
                flushPendingActivity()
            }
        }
    }

    private func flushPendingActivity() {
        guard !pendingActivity.isEmpty else { return }
        recentAudioActivity.append(contentsOf: pendingActivity)
        pendingActivity.removeAll()
        pruneRecentDates()
    }

    /// The graph's visibility probe reports here so buffered samples land
    /// before the first visible frame.
    func setGraphVisible(_ visible: Bool) {
        graphIsOnScreen = visible
        if visible {
            flushPendingActivity()
        }
    }

    private func pruneRecentDates(now: Date = Date()) {
        // 120 s keeps the 30 s graph honest with slack for late-polled
        // entries; stalls also serve the advisor's three-minute window.
        recentOverloadDates.removeAll { $0 < now.addingTimeInterval(-120) }
        recentStallDates.removeAll { $0 < now.addingTimeInterval(-StallAdvisor.window) }
        recentAudioActivity.removeAll { $0 < now.addingTimeInterval(-120) }
    }

    /// The popover just opened; give its graph the freshest log window
    /// instead of whatever is left of the current poll interval.
    func pollSignalsNow() {
        logMonitor.pollNow()
    }

    /// Overload events that `coreaudiod` recorded in the unified log. These
    /// are the overloads the property listener cannot hear: the ones that
    /// happened in some other process's IO cycle, which, in the field, is
    /// where the audible fault actually lives. They enter the same pipeline
    /// as listener signals, so every suppression window, threshold, and
    /// safety gate applies to both witnesses identically.
    private func handleLogOverloads(eventDates: [Date]) {
        guard let newest = eventDates.max() else { return }
        let snapshot = (try? CoreAudioReader.defaultOutputSnapshot()) ?? .unavailable
        handle(AudioSignalBatch(
            date: newest,
            overloads: UInt64(eventDates.count),
            abnormalStops: 0,
            defaultOutputChanges: 0,
            sampleRateChanges: 0,
            deviceStateChanges: 0,
            serviceRestarts: 0,
            device: snapshot,
            source: .systemLog,
            overloadDates: eventDates
        ))
    }

    private func handleMonitorError(_ error: Error) {
        lastError = error.localizedDescription
        record(.init(kind: .monitorError, summary: error.localizedDescription))

        guard !monitor.isAttached else { return }

        monitoringState = .failed("Fennec stopped listening: \(error.localizedDescription)")
        needsAttention = true

        guard !monitorRecoveryInFlight else { return }
        monitorRecoveryInFlight = true
        Task { [weak self] in
            // One automatic retry, after the graph has had a moment. If the
            // machine is mid-restart this usually succeeds; if it does not,
            // the user gets a Restart Monitor button rather than silence.
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.monitorRecoveryInFlight = false
            guard !self.monitor.isAttached else { return }
            self.record(.init(kind: .monitorStarted, summary: "Retrying the Core Audio listener graph."))
            self.restartMonitoring()
        }
    }

    private func notifyUnrepaired(_ decision: DetectionDecision, blocker: String?, episodeID: UUID) {
        guard settings.notifyOnDetection else { return }
        guard faultEpisodes.isCurrent(episodeID) else { return }
        guard detectionNotificationBudget.allow() else { return }
        let suppressed = detectionNotificationBudget.suppressedSinceLastPost()
        detectionNotificationBudget.clearSuppressed()
        notificationController.postUnrepairedDetection(
            // The banner gets the plain sentence; `reason` stays technical
            // for the event log, which is where precision belongs (T-043).
            reason: decision.plainReason,
            blocker: blocker,
            alsoSuppressed: suppressed,
            episodeID: episodeID
        )
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
