import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var helper: HelperManager

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        _helper = ObservedObject(wrappedValue: model.helperManager)
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
        .background(background)
        .alert(item: $model.manualRepairWarning) { warning in
            Alert(
                title: Text("Audio is in use"),
                message: Text(warning.message),
                primaryButton: .destructive(Text("Repair Anyway")) {
                    model.confirmManualRepair()
                },
                secondaryButton: .cancel {
                    model.cancelManualRepair()
                }
            )
        }
        .task { model.refreshAll() }
    }

    private var background: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            Circle()
                .fill(FennecBrand.sky.opacity(0.08))
                .frame(width: 180, height: 180)
                .offset(x: 62, y: -96)
            Circle()
                .fill(FennecBrand.dune.opacity(0.07))
                .frame(width: 150, height: 150)
                .offset(x: 105, y: -44)
        }
        .allowsHitTesting(false)
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

            Spacer()

            if model.isRepairing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(FennecBrand.sky)
                    .accessibilityHidden(true)
            }
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(FennecBrand.dune)
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
            Button {
                model.requestManualRepair()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(model.isRepairing ? "Resetting Core Audio…" : "Fix Audio Now")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(FennecBrand.sky)
            .disabled(model.isRepairing)

            Toggle(isOn: $settings.autoRepairEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-fix crackling")
                        .font(.subheadline.weight(.medium))
                    Text(helper.state.isReachable ? "Fennec will reset Core Audio when a failure is detected." : "Enable the helper to repair automatically.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!helper.state.isReachable)

            if !helper.state.isReachable {
                helperSetupRow
            }

            if let lastDetectionDate = model.lastDetectionDate {
                HStack(alignment: .firstTextBaseline) {
                    Label("Last suspected crackle", systemImage: "ear.badge.waveform")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastDetectionDate, style: .relative)
                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var helperSetupRow: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(FennecBrand.dune)
            VStack(alignment: .leading, spacing: 1) {
                Text("Automatic repair helper")
                    .font(.caption.weight(.semibold))
                Text(helper.state.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            switch helper.state {
            case .awaitingApproval:
                Button("Approve") { helper.openApprovalSettings() }
                    .controlSize(.small)
            default:
                Button("Enable") { helper.register() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(FennecBrand.dune.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Listening for Core Audio trouble")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit") { model.quit() }
                .buttonStyle(.plain)
        }
        .font(.caption)
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
    }
}
