import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var helper: HelperManager
    @ObservedObject private var loginItem: LoginItemManager
    @ObservedObject private var notifications: NotificationController

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        _helper = ObservedObject(wrappedValue: model.helperManager)
        _loginItem = ObservedObject(wrappedValue: model.loginItemManager)
        _notifications = ObservedObject(wrappedValue: model.notificationController)
    }

    @State private var confirmingHelperRemoval = false

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
        .confirmationDialog(
            "Remove Fennec's root helper?",
            isPresented: $confirmingHelperRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Helper", role: .destructive) { helper.unregister() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Automatic repair stops immediately. Turning it back on needs your approval in System Settings again.")
        }
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
                        .help("Tear down and rebuild Fennec's Core Audio listeners. Does not touch your audio.")
                    Button("Repair Audio Now") { model.requestManualRepair() }
                        .buttonStyle(.borderedProminent)
                        .tint(FennecBrand.sky)
                        .disabled(model.isRepairing || model.isPreparingRepair)
                        .help("Restart Core Audio now. Playback and recording stop for about a second.")
                }
            }

            Section("Automatic Repair") {
                Toggle("Repair crackling automatically", isOn: $settings.autoRepairEnabled)
                    .disabled(!helper.state.isReachable)
                Text("One overload is usually a harmless blip. Two in a row is the failure that stays broken until Core Audio restarts, so Fennec waits for the second one, then fixes it.")
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

            Section("Notifications") {
                Toggle("Tell me after Fennec repairs the audio", isOn: $settings.notifyOnRepair)
                Toggle("Tell me when crackling is detected but not repaired", isOn: $settings.notifyOnDetection)

                if notifications.authorizationChecked && !notifications.isAuthorized {
                    // Without this the screen shows two switches that are on
                    // and produce nothing: the same "promise Fennec cannot
                    // keep" the auto-repair notice forty lines up exists to
                    // prevent.
                    Label {
                        Text("macOS is not allowing Fennec to notify you, so these do nothing.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(FennecBrand.dune)
                    }
                    Button("Open Notification Settings…") { notifications.openSystemSettings() }
                }

                Text("A repair that failed always notifies you; that is the one case where something is left for you to do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button("Disable Helper…") { confirmingHelperRemoval = true }
                    .tint(.red)
            }
        }

        Text("The helper can only restart Core Audio; it cannot be given a command, a path, or an argument. With it enabled, repairs never show a password prompt. Without it, Fennec can still repair by asking for your administrator password, but only after showing you the command.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Button("What Fennec can do to this Mac…") { model.showAboutWindow() }
            .buttonStyle(.link)
            .font(.caption)

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
                    LabeledContent("Automatic repair", value: model.pauseStatusText ?? "Paused")
                    Button("Resume Listening") { model.resume() }
                } else {
                    // Not "Status": General has a Status row driven by the
                    // monitor, and two rows with the same label in one window,
                    // one of them false, is worse than no row.
                    LabeledContent("Automatic repair", value: model.isArmed ? "Armed" : "Not armed")
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
                LabeledContent("Wait between repairs") {
                    HStack(spacing: 12) {
                        Slider(value: $settings.cooldownSeconds, in: 20...180, step: 5)
                            .tint(FennecBrand.dune)
                            .frame(minWidth: 180)
                            .accessibilityLabel("Wait between repairs")
                            .accessibilityValue("\(Int(settings.cooldownSeconds)) seconds")
                        Text("\(Int(settings.cooldownSeconds)) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("After any repair attempt, successful or not, Fennec will not try again until this has passed.")
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
        // Form supplies its own insets and its own scrolling; a bare VStack
        // does neither, so an unbounded error string used to push the content
        // out of a window that could not be resized.
        ScrollView {
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
                Button("Repair History…") { model.showActivityWindow() }
                Button("Reveal Event Log") { model.openEventLog() }
                Button("About & Uninstall…") { model.showAboutWindow() }
                Spacer()
                if let lastRepairDate = model.lastRepairDate {
                    Text("Last repair \(lastRepairDate.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Recent Events") {
                // No empty branch: `startMonitoring()` records an event before
                // this view can ever be built, so it was dead code.
                Group {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            .padding(20)
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
