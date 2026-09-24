import AppKit
import SwiftUI

/// First run puts the repair choice, setup, and an explicit test in one place.
/// The test runs only when the user presses its button.
struct WelcomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var helper: HelperManager
    @ObservedObject private var loginItem: LoginItemManager
    @ObservedObject private var notifications: NotificationController
    @ObservedObject private var history: RepairHistoryStore

    private let location = InstallLocation.current()

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        _helper = ObservedObject(wrappedValue: model.helperManager)
        _loginItem = ObservedObject(wrappedValue: model.loginItemManager)
        _notifications = ObservedObject(wrappedValue: model.notificationController)
        _history = ObservedObject(wrappedValue: model.repairHistory)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    masthead
                    if location.warning != nil { locationNotice }
                    repairChoice
                    setupSection
                    if location.warning != nil || loginItem.requiresApproval { dragWell }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

            Divider()
            rehearsal
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 540)
        .fennecConfirmation(model)
        .task { model.refreshAll() }
    }

    private var masthead: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("FennecMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Fennec")
                    .font(.system(size: 27, weight: .semibold, design: .default))
                Text("Sound crackling? Fennec handles it.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var locationNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(FennecBrand.dune)
                .accessibilityHidden(true)
            Text(location.warning ?? "")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let title = location.actionTitle {
                Button(title) {
                    if case .elsewhere = location {
                        model.moveToApplications()
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
                .layoutPriority(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.dune.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var repairChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How should Fennec handle crackling?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("Repair mode", selection: $settings.repairMode) {
                ForEach(RepairMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.repairMode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Repairing stops all sound on this Mac. Fennec checks for active calls and recording before it acts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FennecBrand.cardStroke, lineWidth: 1)
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set it up", systemImage: "slider.horizontal.3")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(model.setupSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.setupSteps) { step in
                SetupStepRow(step: step, compact: false) {
                    model.performSetupAction(for: step)
                }
            }

            if let error = helper.lastError ?? model.installError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = loginItem.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The icon carries the real bundle into Applications or Login Items when
    /// macOS needs the user to drag it there.
    private var dragWell: some View {
        HStack(spacing: 13) {
            DraggableAppIcon()
            VStack(alignment: .leading, spacing: 3) {
                Text(loginItem.requiresApproval
                     ? "Drag Fennec into Login Items"
                     : "Drag Fennec into Applications")
                    .font(.callout.weight(.medium))
                Text(loginItem.requiresApproval
                     ? "macOS is waiting for you to allow it to start at login."
                     : "Keep the app there so macOS can find its repair helper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var rehearsal: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(RepairCopy.onboardingTestTitle, systemImage: "play.circle")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if !replayReady {
                Text(RepairCopy.onboardingTestDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if !replayReady || (settings.showRepairFox && !reduceMotion) {
                    Button {
                        model.requestRehearsalRepair()
                    } label: {
                        Label(
                            replayReady
                                ? RepairCopy.onboardingReplayButton
                                : (model.isRepairing || model.isPreparingRepair
                                    ? RepairCopy.onboardingTestWorking : RepairCopy.onboardingTestButton),
                            systemImage: RepairCopy.primaryButtonSymbol(for: .idle)
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FennecBrand.sky)
                        .disabled(replayReady
                        ? model.onboardingFoxRequestCount >= RepairFoxBurst.maximumTotal
                        : model.isRepairing || model.isPreparingRepair)
                    .help(replayReady
                        ? RepairCopy.onboardingReplayHelp : RepairCopy.onboardingTestDetail)
                }
                if !model.hasCompletedOnboardingRepair && (model.isRepairing || model.isPreparingRepair) {
                    ProgressView().controlSize(.small)
                }
            }

            if let repair = testRepair {
                Label(RepairCopy.receiptHeadline(for: repair), systemImage: repair.outcome.symbolName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(FennecBrand.accent(for: repair.outcome))
            }
        }
    }

    private var testRepair: RepairRecord? {
        guard let id = model.lastRepairID else { return nil }
        return history.records.first { $0.id == id && $0.trigger == .rehearsal }
    }

    /// Replays can be queued from the first click, even while the safety
    /// check is still preparing the one actual repair.
    private var replayReady: Bool {
        model.onboardingFoxRequestCount > 0 || model.hasCompletedOnboardingRepair
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Fennec stays in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                model.completeFirstRun()
                WindowPresenter.shared.close(WindowPresenter.ID.welcome)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(FennecBrand.sky)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
