import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var helper: HelperManager
    @ObservedObject private var loginItem: LoginItemManager

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        _helper = ObservedObject(wrappedValue: model.helperManager)
        _loginItem = ObservedObject(wrappedValue: model.loginItemManager)
    }

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            Divider()
            TabView {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                safetyTab
                    .tabItem { Label("Safety", systemImage: "shield") }
                diagnosticsTab
                    .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            }
            .padding(18)
        }
        .frame(width: 650, height: 560)
        .task { model.refreshAll() }
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
    }

    private var brandHeader: some View {
        HStack(spacing: 13) {
            Image("FennecMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Fennec")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Keeps Core Audio clean while your Mac works hard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.monitoringState.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(FennecBrand.card, in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(
            LinearGradient(
                colors: [FennecBrand.sky.opacity(0.10), FennecBrand.dune.opacity(0.06), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var generalTab: some View {
        Form {
            Section("Listening") {
                LabeledContent("Status", value: model.monitoringState.title)
                LabeledContent("Current output", value: model.currentDevice.name)
                LabeledContent("Sample rate", value: sampleRateText)

                HStack {
                    Button("Restart Monitor") { model.restartMonitoring() }
                    Button("Fix Audio Now") { model.requestManualRepair() }
                        .buttonStyle(.borderedProminent)
                        .tint(FennecBrand.sky)
                        .disabled(model.isRepairing)
                }
            }

            Section("Automatic Repair") {
                Toggle("Auto-fix after a likely crackle event", isOn: $settings.autoRepairEnabled)
                    .disabled(!helper.state.isReachable)

                Picker("Detection sensitivity", selection: $settings.sensitivity) {
                    ForEach(DetectionSensitivity.allCases) { sensitivity in
                        Text(sensitivity.title).tag(sensitivity)
                    }
                }
                Text(settings.sensitivity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                helperControls
            }

            Section("Startup") {
                Toggle(
                    "Launch Fennec at login",
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    )
                )
                if loginItem.requiresApproval {
                    HStack {
                        Text("Login item approval is required in System Settings.")
                            .foregroundStyle(FennecBrand.dune)
                        Spacer()
                        Button("Open Login Items") { loginItem.openSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var helperControls: some View {
        LabeledContent("Privileged helper") {
            HStack(spacing: 6) {
                Circle()
                    .fill(helper.state.isReachable ? FennecBrand.sky : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(helper.state.title)
            }
        }

        HStack {
            switch helper.state {
            case .notConfigured, .unavailable:
                Button("Enable Helper") { helper.register() }
            case .awaitingApproval:
                Button("Open Approval Settings") { helper.openApprovalSettings() }
            case .enabled:
                Button("Recheck Helper") { helper.refreshStatus(testReachability: true) }
                Button("Disable Helper") { helper.unregister() }
            }
        }

        Text("The helper can only restart Core Audio. It cannot run arbitrary commands, and automatic repair never displays a password prompt.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if let error = helper.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var safetyTab: some View {
        Form {
            Section("Do Not Interrupt") {
                Toggle("Skip auto-fix while any microphone input is active", isOn: $settings.protectMicrophone)
                Toggle("Skip auto-fix while a call or recording app is using audio", isOn: $settings.protectCommunicationApps)
                Toggle("Skip auto-fix for Bluetooth outputs", isOn: $settings.skipBluetooth)
            }

            Section("Rate Limiting") {
                Slider(value: $settings.cooldownSeconds, in: 20...180, step: 5) {
                    Text("Cooldown")
                }
                .tint(FennecBrand.dune)
                LabeledContent("Cooldown between repairs", value: "\(Int(settings.cooldownSeconds)) seconds")
            }

            Section("Notifications") {
                Toggle("Notify me when crackling is suspected", isOn: $settings.notifyOnDetection)
            }

            Section {
                Label {
                    Text("Restarting coreaudiod briefly disconnects Core Audio playback and recording. Fennec's safety checks reduce the chance of interrupting a call or recording; manual repair always remains available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "ear")
                        .foregroundStyle(FennecBrand.dune)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Current Audio Path") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                    diagnosticRow("Device", model.currentDevice.name)
                    diagnosticRow("Transport", model.currentDevice.transport.title)
                    diagnosticRow("Sample rate", sampleRateText)
                    diagnosticRow("Device UID", model.currentDevice.uid.isEmpty ? "—" : model.currentDevice.uid)
                    diagnosticRow("Device alive", model.currentDevice.isAlive ? "Yes" : "No")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack(spacing: 10) {
                diagnosticMetric("Overloads", model.overloadSignalCount, accent: FennecBrand.dune)
                diagnosticMetric("Abnormal stops", model.abnormalStopCount, accent: FennecBrand.dune)
                diagnosticMetric("Detections", UInt64(model.detectionCount), accent: FennecBrand.sky)
                diagnosticMetric("Repairs", UInt64(model.repairCount), accent: FennecBrand.sky)
            }

            HStack {
                Button("Refresh") { model.refreshAll() }
                Button("Reveal Event Log") { model.openEventLog() }
                Spacer()
                if let lastRepairDate = model.lastRepairDate {
                    Text("Last repair \(lastRepairDate.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Recent Activity") {
                if model.recentActivity.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "ear")
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.recentActivity) { activity in
                                HStack(alignment: .top) {
                                    Text(activity.date, style: .time)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 72, alignment: .leading)
                                    Text(activity.summary)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(minHeight: 150)
                }
            }

            if let lastError = model.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
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
        return String(format: "%.0f Hz", model.currentDevice.sampleRate)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func diagnosticMetric(_ title: String, _ value: UInt64, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 24, height: 3)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
