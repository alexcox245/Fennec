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
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            safetyTab
                .tabItem { Label("Safety", systemImage: "shield") }
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }
        .frame(minWidth: 650, minHeight: 560)
        .task { model.refreshAll() }
        .fennecConfirmation(model)
    }

    private var generalTab: some View {
        Form {
            Section("Listening") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(model.monitoringState.title)
                    }
                }
                LabeledContent("Current output", value: model.currentDevice.name)
                LabeledContent("Sample rate", value: sampleRateText)

                HStack {
                    Button("Restart Monitor") { model.restartMonitoring() }
                    Button("Repair Audio Now") { model.requestManualRepair() }
                        .buttonStyle(.borderedProminent)
                        .tint(FennecBrand.sky)
                        .disabled(model.isRepairing)
                }
            }

            Section("Automatic Repair") {
                Toggle("Repair crackling automatically", isOn: $settings.autoRepairEnabled)
                    .disabled(!helper.state.isReachable)
                Text("One overload is usually a harmless blip. Two in a row is the failure that stays broken until Core Audio restarts — so Fennec waits for the second one, then fixes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !helper.state.isReachable {
                    // Without this the screen reads "Repair crackling
                    // automatically: on" directly above "Privileged helper:
                    // Not configured", which is a promise Fennec cannot keep.
                    Label {
                        Text("This switch does nothing until the repair helper is enabled. Fennec will still detect crackling and tell you about it.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(FennecBrand.dune)
                    }
                }

                Picker("Step in after", selection: $settings.sensitivity) {
                    ForEach(DetectionSensitivity.allCases) { sensitivity in
                        Text(sensitivity.title).tag(sensitivity)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.sensitivity.detail)
                    Text(settings.sensitivity.experience)
                        .foregroundStyle(FennecBrand.dune)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                helperControls
            }

            Section("Startup") {
                Toggle(
                    "Start Fennec when I log in",
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    )
                )

                LabeledContent("Login item") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(loginItem.isEnabled ? FennecBrand.sky : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(loginItem.state.title)
                    }
                }

                Text(loginItem.state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if loginItem.requiresApproval {
                    HStack {
                        Text("macOS is holding this until you allow it.")
                            .font(.caption)
                            .foregroundStyle(FennecBrand.dune)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSettings() }
                    }
                }

                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if !model.remainingSetupSteps.isEmpty {
                Section("Finish Setup") {
                    ForEach(model.remainingSetupSteps) { step in
                        SetupStepRow(step: step, compact: false) {
                            model.performSetupAction(for: step)
                        }
                    }
                    Text(model.setupSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Toggle("Never repair while a microphone is live", isOn: $settings.protectMicrophone)
                Toggle("Never repair while a call or recording app is using audio", isOn: $settings.protectCommunicationApps)
                Toggle("Never repair Bluetooth outputs", isOn: $settings.skipBluetooth)
            }

            Section("Pause") {
                if model.isPaused {
                    LabeledContent("Status", value: model.pauseStatusText ?? "Paused")
                    Button("Resume Watching") { model.resume() }
                } else {
                    LabeledContent("Status", value: "Watching")
                    Menu("Pause Automatic Repair") {
                        ForEach(PauseSchedule.Option.allCases) { option in
                            Button(option.title) { model.pause(option) }
                        }
                    }
                    .fixedSize()
                }
                Text("Pausing stops automatic repair only. Repair Audio Now keeps working, and every duration except the last one expires on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Rate Limiting") {
                Slider(value: $settings.cooldownSeconds, in: 20...180, step: 5) {
                    Text("Cooldown")
                }
                .tint(FennecBrand.dune)
                LabeledContent("Cooldown between repairs", value: "\(Int(settings.cooldownSeconds)) seconds")
            }

            Section("Notifications") {
                Toggle("Tell me after Fennec repairs the audio", isOn: $settings.notifyOnRepair)
                Toggle("Tell me when crackling is detected but not repaired", isOn: $settings.notifyOnDetection)
                Text("A repair that failed always notifies you — that is the one case where something is left for you to do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button("About & Uninstall…") { model.showAboutWindow() }
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
