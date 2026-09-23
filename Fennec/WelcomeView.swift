import AppKit
import SwiftUI

/// First run is a short choice and a consent record, not a tour. Users can
/// choose unattended repair or a foreground question, then finish setup later.
struct WelcomeView: View {
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
                    if settings.repairMode == .automatic { automaticSetup }
                    optionalSetup
                    if loginItem.requiresApproval { dragWell }
                    rehearsal
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

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

    private var automaticSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Automatic repair", systemImage: "waveform.badge.mic")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if model.remainingSetupSteps.isEmpty {
                Label("Ready when Fennec is open", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(FennecBrand.sky)
            } else {
                ForEach(model.remainingSetupSteps) { step in
                    SetupStepRow(step: step, compact: false) {
                        model.performSetupAction(for: step)
                    }
                }
            }

            if let error = helper.lastError ?? model.installError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var optionalSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Toggle(
                "Start Fennec when I log in",
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            )

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notifications")
                        .font(.callout.weight(.medium))
                    Text("Banners for repairs and detections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if notifications.authorizationChecked && !notifications.isAuthorized {
                    Button("Notification Settings…") { notifications.openSystemSettings() }
                } else {
                    Button(notifications.isAuthorized ? "Allowed" : "Allow") {
                        notifications.requestAuthorization()
                    }
                    .disabled(notifications.isAuthorized)
                }
            }

            if let error = loginItem.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Lets the user drag the real bundle into Login Items when macOS requires
    /// that route. The icon remains available in the context where it helps.
    private var dragWell: some View {
        HStack(spacing: 13) {
            DraggableAppIcon()
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag Fennec into Login Items")
                    .font(.callout.weight(.medium))
                Text("macOS is waiting for you to allow it to start at login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var rehearsal: some View {
        DisclosureGroup("Try a repair once") {
            VStack(alignment: .leading, spacing: 10) {
                Text("This stops audio while Fennec restarts it. Every app stays open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(model.isRepairing || model.isPreparingRepair ? "Repairing…" : "Repair Audio") {
                        model.requestRehearsalRepair()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRepairing || model.isPreparingRepair)
                    if model.isRepairing || model.isPreparingRepair {
                        ProgressView().controlSize(.small)
                    }
                }

                if let repair = testRepair {
                    Label(RepairCopy.receiptHeadline(for: repair), systemImage: repair.outcome.symbolName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(FennecBrand.accent(for: repair.outcome))
                }
            }
            .padding(.top, 8)
        }
        .font(.callout.weight(.medium))
    }

    private var testRepair: RepairRecord? {
        guard let id = model.lastRepairID else { return nil }
        return history.records.first { $0.id == id && $0.trigger == .rehearsal }
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
