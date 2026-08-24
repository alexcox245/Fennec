import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var helper: HelperManager
    @ObservedObject private var history: RepairHistoryStore
    @ObservedObject private var loginItem: LoginItemManager
    @ObservedObject private var notifications: NotificationController

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        _helper = ObservedObject(wrappedValue: model.helperManager)
        _history = ObservedObject(wrappedValue: model.repairHistory)
        _loginItem = ObservedObject(wrappedValue: model.loginItemManager)
        _notifications = ObservedObject(wrappedValue: model.notificationController)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            deviceCard
            repairControls
            footer
        }
        .padding(16)
        .frame(width: 384)
        .task {
            model.refreshAll()
            // Only here: this is the moment the user has actually looked.
            model.acknowledgeAttention()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("FennecMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(FennecBrand.cream.opacity(0.8), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Fennec")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Fennec, \(statusTitle)")

            Spacer(minLength: 8)

            repairTally
        }
    }

    /// Pause is a header control, not a setting: it is the thing a person
    /// reaches for in the ten seconds before they hit record.
    private var pauseControl: some View {
        Group {
            if model.isPaused {
                HStack(spacing: 8) {
                    Button {
                        model.resume()
                    } label: {
                        Label("Resume Watching", systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .help("Start watching for crackling again now.")
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(PauseSchedule.Option.allCases) { option in
                            Button(option.title) { model.pause(option) }
                        }
                    } label: {
                        Label("Pause", systemImage: "pause.circle")
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Stop repairing automatically for a while. Repair Audio Now still works.")

                    Text("Stops automatic repair only.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    /// The running total. Small, monospaced, and unglamorous — but it is the
    /// only proof a background utility ever offers that it earned its place.
    private var repairTally: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(RepairCopy.headlineNumber(for: history.summary))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(history.summary.successes > 0 ? FennecBrand.gold : Color.secondary)
            Text(history.summary.successes == 1 ? "repair" : "repairs")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RepairCopy.summaryLine(for: history.summary))
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(FennecBrand.dune)
                    .accessibilityHidden(true)
                Text(model.currentDevice.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(model.currentDevice.transport.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }

            Text(model.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                // 25: these are session counters and the header tally is a
                // lifetime one. Side by side with no scope they read as one
                // population, so after any relaunch the row said
                // "SIGNALS 0 · REPAIRS 7". The lifetime number lives in the
                // header; this row says what it is.
                metric(title: "FORMAT", value: sampleRateText)
                metric(title: "SIGNALS TODAY", value: "\(model.overloadSignalCount + model.abnormalStopCount)")
                metric(title: "DETECTIONS", value: "\(model.detectionCount)")
            }
        }
        .padding(13)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FennecBrand.cardStroke, lineWidth: 1)
        }
    }

    private var repairControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let confirmation = model.pendingConfirmation {
                confirmationCard(confirmation)
            } else {
                Button {
                    model.requestManualRepair()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(primaryButtonTitle)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(FennecBrand.sky)
                .disabled(model.isRepairing || model.isPreparingRepair)
                .keyboardShortcut(.defaultAction)
                .help("Restart Core Audio now. Playback and recording stop for about a second.")
            }

            Toggle(isOn: $settings.autoRepairEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repair crackling automatically")
                        .font(.subheadline.weight(.medium))
                    Text(autoRepairDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(!helper.state.isReachable)

            if let lastError = model.lastError {
                VStack(alignment: .leading, spacing: 7) {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    // The surface that announces the failure has to offer the
                    // remedy. Restart Monitor used to live only on the
                    // Settings General tab, which is not where anyone looks
                    // when the popover says something is wrong.
                    if case .failed = model.monitoringState {
                        Button("Restart Monitor") { model.restartMonitoring() }
                            .controlSize(.small)
                            .help("Tear down and rebuild Fennec's Core Audio listeners.")
                    }
                }
            }
            pauseControl

            if let standDown = model.standDown, standDown.isActive(at: Date()) {
                standDownCard(standDown)
            }

            if !model.remainingSetupSteps.isEmpty {
                setupCard
            }

            if let repair = history.records.first {
                receiptCard(repair)
            }

            daysWithoutIncidentSign

            if let throttle = model.throttleNotice {
                Label(HelperThrottle.userFacing(throttle), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    /// The sign on the workshop wall.
    ///
    /// A background utility that works is indistinguishable from one that
    /// does nothing. This is the honest answer to that — not a dashboard, one
    /// number that means something, kept the way a real safety sign is kept.
    /// It counts up while nothing goes wrong and reads 0 on the day something
    /// does, with no softening.
    ///
    /// It is sand and ink in both appearances on purpose: a sign is a
    /// physical object, and physical objects do not invert at dusk. Sand is a
    /// surface here and ink is the number, which is exactly what the palette
    /// reserves them for.
    private var daysWithoutIncidentSign: some View {
        let record = model.daysWithoutIncident
        return Button {
            model.showActivityWindow()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("DAYS WITHOUT INCIDENT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.9)
                    Text(record.caption)
                        .font(.caption2)
                        .opacity(0.7)
                }
                Spacer(minLength: 8)
                Text("\(record.days)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(FennecBrand.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FennecBrand.sand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(FennecBrand.ink.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Open Fennec Activity — every repair, grouped by day.")
        .accessibilityLabel(record.accessibilityLabel)
        .accessibilityHint("Opens Fennec Activity.")
    }

    /// Fennec has stopped trying, and says why in the machine's own numbers.
    ///
    /// This is the hardest thing the product has to say — that the fault is
    /// probably not Core Audio's — and it says it without apologising and
    /// without pretending it can be fixed by trying harder.
    private func standDownCard(_ standDown: RepairGovernor.StandDown) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Stopped restarting Core Audio")
                    .font(.caption.weight(.bold))
                Spacer()
            }

            Text(standDown.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Try Again Anyway") { model.clearStandDown() }
                    .controlSize(.small)
                Button("See What Happened") { model.showActivityWindow() }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.red.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fennec stopped restarting Core Audio. \(standDown.reason)")
    }

    /// Asked inline, never as an alert.
    ///
    /// An `.alert` raised from a `MenuBarExtra(.window)` scene dismisses the
    /// popover that is presenting it, so the dialog appears and vanishes in
    /// the same frame. This card lives in the popover's own layout and cannot.
    private func confirmationCard(_ confirmation: PendingConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: confirmation.isDestructive ? "exclamationmark.triangle.fill" : "lock.fill")
                    .foregroundStyle(FennecBrand.dune)
                    .accessibilityHidden(true)
                Text(confirmation.title)
                    .font(.subheadline.weight(.semibold))
            }

            Text(confirmation.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = confirmation.monospacedDetail {
                Text(detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack(spacing: 8) {
                Spacer()
                Button(confirmation.cancelTitle) { model.cancel(confirmation) }
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle) { model.confirm(confirmation) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(confirmation.isDestructive ? .red : FennecBrand.sky)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.dune.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(FennecBrand.dune.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(confirmation.accessibilityDescription)
    }

    /// The receipt. Aviator gold is reserved in the brand for exactly this —
    /// a repair that worked — so it appears nowhere else in the app.
    private func receiptCard(_ repair: RepairRecord) -> some View {
        // Outcome, never `succeeded`. `succeeded` is fixed at repair time; a
        // gold seal above "Restarted, but the fault came back" is one card
        // asserting two opposite things.
        let accent = FennecBrand.accent(for: repair.outcome)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: repair.outcome.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(RepairCopy.receiptHeadline(for: repair))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(repair.date, style: .relative)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .layoutPriority(-1)
                }
                Text(RepairCopy.receiptDetail(for: repair))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(RepairCopy.receiptHeadline(for: repair)). \(RepairCopy.receiptDetail(for: repair))")
    }

    /// Everything still standing between the user and unattended repair, with
    /// the button that resolves it. It disappears the moment setup is done —
    /// a checklist that lingers is just clutter.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.caption)
                        .foregroundStyle(FennecBrand.dune)
                        .accessibilityHidden(true)
                    Text("Finish setup")
                        .font(.caption.weight(.bold))
                        .tracking(0.3)
                    Spacer()
                }
                Text(model.setupSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.remainingSetupSteps) { step in
                Divider().opacity(0.4)
                SetupStepRow(step: step, compact: true) {
                    model.performSetupAction(for: step)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.dune.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(FennecBrand.dune.opacity(0.22), lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                WindowPresenter.shared.showSettings(model: model)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Open Fennec Settings.")

            Spacer()

            Text(footerStatus)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(model.setupSummary)

            Spacer()

            Menu {
                Button("Repair History") { model.showActivityWindow() }
                Divider()
                Button("What Fennec Does") { model.showWelcomeWindow() }
                Button("About & Uninstall…") { model.showAboutWindow() }
                Divider()
                Button("Reveal Event Log") { model.openEventLog() }
            } label: {
                Label("More", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What Fennec does to this Mac, the event log, and how to remove it.")

            Button("Quit") { model.quit() }
                .buttonStyle(.plain)
                .help("Quit Fennec. It stops listening until you open it again.")
        }
        .font(.caption)
    }

    /// Two facts compete for one line. Until Fennec has ever repaired
    /// anything, the reassuring one wins; after that, the count does.
    private var footerStatus: String {
        if history.summary.successes > 0 {
            return RepairCopy.summaryLine(for: history.summary)
        }
        return loginItem.isEnabled
            ? "Running in the background since login"
            : "Listening for Core Audio trouble"
    }

    private var primaryButtonTitle: String {
        if model.isRepairing { return "Restarting Core Audio…" }
        // Under heavy load — Fennec's own premise — the safety scan is slow
        // enough that the button used to look untouched after a click.
        if model.isPreparingRepair { return "Checking what is using audio…" }
        return "Repair Audio Now"
    }

    private var autoRepairDetail: String {
        if let pauseStatus = model.pauseStatusText {
            return "\(pauseStatus). Repair Audio Now still works."
        }
        // AirPods and Bluetooth headphones are the majority output on a modern
        // Mac, and `skipBluetooth` defaults on. Without this the popover said
        // "You hear the fault start, then it is gone" two rows under a
        // BLUETOOTH badge, over a device it will never touch.
        if settings.skipBluetooth && model.currentDevice.transport.isBluetooth {
            return "Off for Bluetooth outputs, which is this one. Repair Audio Now still works."
        }
        guard helper.state.isReachable else {
            return "Enable the helper below to let Fennec repair without a password prompt."
        }
        guard settings.autoRepairEnabled else {
            return "Fennec will detect crackling but wait for you to press Repair Audio Now."
        }
        return settings.sensitivity.detail
    }

    /// While paused, the pause is the status. Nothing else about Fennec
    /// matters more to a user who deliberately switched it off.
    private var statusTitle: String {
        model.pauseStatusText ?? model.monitoringState.title
    }

    private var statusColor: Color {
        if model.isPaused { return FennecBrand.dune }
        switch model.monitoringState {
        case .monitoring: return FennecBrand.sky
        case .starting: return FennecBrand.sand
        case .stopped: return FennecBrand.dune
        case .failed: return .red
        }
    }

    private var sampleRateText: String {
        guard model.currentDevice.sampleRate > 0 else { return "—" }
        return String(format: "%.1f kHz", model.currentDevice.sampleRate / 1_000)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
