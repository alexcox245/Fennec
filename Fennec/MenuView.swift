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
        .task { model.refreshAll() }
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
                    Text(model.monitoringState.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Fennec, \(model.monitoringState.title)")

            Spacer()

            repairTally
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
                metric(title: "FORMAT", value: sampleRateText)
                metric(title: "SIGNALS", value: "\(model.overloadSignalCount + model.abnormalStopCount)")
                metric(title: "REPAIRS", value: "\(model.repairCount)")
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
                        Text(model.isRepairing ? "Restarting Core Audio…" : "Repair Audio Now")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(FennecBrand.sky)
                .disabled(model.isRepairing)
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

            if !model.remainingSetupSteps.isEmpty {
                setupCard
            }

            if let repair = history.records.first {
                receiptCard(repair)
            } else if let lastDetectionDate = model.lastDetectionDate {
                HStack(alignment: .firstTextBaseline) {
                    Label("Last suspected crackle", systemImage: "ear.badge.waveform")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastDetectionDate, style: .relative)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
            }

            if let lastError = model.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        let accent = repair.succeeded ? FennecBrand.gold : Color.red

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: repair.succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
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

            Button("Quit") { model.quit() }
                .buttonStyle(.plain)
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

    private var autoRepairDetail: String {
        guard helper.state.isReachable else {
            return "Enable the helper below to let Fennec repair without a password prompt."
        }
        guard settings.autoRepairEnabled else {
            return "Fennec will detect crackling but wait for you to press Repair Audio Now."
        }
        return settings.sensitivity.detail
    }

    private var statusColor: Color {
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
