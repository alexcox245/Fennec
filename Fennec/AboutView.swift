import AppKit
import SwiftUI

/// About, but useful.
///
/// The standard macOS About panel shows a version number and a copyright
/// line. For a 3 MB app from an unknown developer that installs a root
/// LaunchDaemon, that is not the information anyone actually wants. This one
/// answers the four questions a person evaluating that decision asks:
///
/// 1. What can it do to my Mac? (all four privileged paths, verbatim)
/// 2. What is *actually* running as root right now? (the helper's own build
///    and path, read back over XPC, because after an in-place update the app
///    and the daemon can disagree)
/// 3. Can I check the code matches the binary? (the source manifest, which is
///    the strongest thing this repo has and was mentioned nowhere a user
///    would look)
/// 4. Can I get rid of it? (completely, including the daemon)
struct AboutView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var helper: HelperManager
    @StateObject private var updater: FennecUpdater
    @ObservedObject private var updateDriver: FennecUpdateDriver
    @StateObject private var uninstaller = Uninstaller()

    @State private var showingUninstall = false
    @State private var confirmingHelperRemoval = false
    @State private var keepLogs = true
    @State private var copiedCommands = false

    init(model: AppModel) {
        self.model = model
        _helper = ObservedObject(wrappedValue: model.helperManager)
        let updater = FennecUpdater(model: model)
        _updater = StateObject(wrappedValue: updater)
        _updateDriver = ObservedObject(wrappedValue: updater.driver)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                masthead
                updateSection
                detailsSection
                removalSection
            }
            .padding(28)
        }
        .frame(minWidth: 540, minHeight: 560)
        .task { model.refreshAll() }
        .sheet(isPresented: $showingUninstall) { uninstallSheet }
        .confirmationDialog(
            "Remove Fennec's root helper?",
            isPresented: $confirmingHelperRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Helper", role: .destructive) { helper.unregister() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Automatic repair stops immediately. Fennec can still ask before a repair that uses your administrator password.")
        }
    }

    // MARK: Sections

    private var masthead: some View {
        HStack(alignment: .top, spacing: 16) {
            Image("FennecMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Fennec")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Software Update", symbol: "arrow.down.circle")
            Text("Check when you choose. Fennec downloads a signed update only after you ask, then waits for Install & Relaunch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            updateStatus
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(FennecBrand.cardStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateDriver.presentation {
        case .idle:
            Button("Check for Updates") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        case .checking:
            updateProgress("Checking for updates…", progress: nil)
            Button("Cancel") { updateDriver.cancelCurrentOperation() }
        case let .available(version, notes, informationOnly, _):
            VStack(alignment: .leading, spacing: 7) {
                Text("Version \(version) is available.")
                    .font(.callout.weight(.medium))
                if !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack {
                if informationOnly {
                    Button("View Release") { updateDriver.openInformationURL() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Download Update") { updateDriver.chooseDownload() }
                        .buttonStyle(.borderedProminent)
                        .tint(FennecBrand.sky)
                }
                Button("Cancel") { updateDriver.cancelAvailableUpdate() }
            }
        case let .downloading(progress):
            updateProgress("Downloading…", progress: progress)
            Button("Cancel Download") { updateDriver.cancelCurrentOperation() }
        case let .extracting(progress):
            updateProgress("Verifying update…", progress: progress)
        case let .preparingInstall(version):
            updateProgress("Preparing version \(version)…", progress: nil)
            Text("Waiting for any active repair to finish.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") { updateDriver.cancelPendingInstallation() }
        case let .readyToInstall(version):
            Text("Version \(version) is ready.")
                .font(.callout.weight(.medium))
            HStack {
                Button("Install & Relaunch") { updateDriver.installAndRelaunch() }
                    .buttonStyle(.borderedProminent)
                    .tint(FennecBrand.sky)
                Button("Cancel") { updateDriver.cancelPendingInstallation() }
            }
        case .installing:
            updateProgress("Installing…", progress: nil)
        case .current:
            Label("Fennec is up to date.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(FennecBrand.sky)
            Button("Check Again") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(FennecBrand.dune)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Try Again") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }

    private func updateProgress(_ title: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 180)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(title).font(.callout)
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("What Fennec can do") {
                VStack(alignment: .leading, spacing: 11) {
                    Text(PrivilegeDisclosure.whyNotAShellAlias)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(PrivilegeDisclosure.privilegedActions) { item in
                        disclosureRow(item)
                    }
                    LabeledContent("Helper running as root", value: helperDescription)
                        .textSelection(.enabled)
                    if let mismatch = helper.versionMismatch {
                        Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(FennecBrand.dune)
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("Privacy and files") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PrivilegeDisclosure.facts) { item in
                        disclosureRow(item)
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("Verify this copy") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Fennec includes a SHA-256 manifest for its source files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(Self.verifyCommands)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button(copiedCommands ? "Copied" : "Copy Commands") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.verifyCommands, forType: .string)
                            copiedCommands = true
                            Task {
                                try? await Task.sleep(for: .milliseconds(1_500))
                                copiedCommands = false
                            }
                        }
                        .disabled(copiedCommands)
                        Button("Reveal Event Log") { model.openEventLog() }
                    }
                }
                .padding(.top, 8)
            }
        }
        .font(.callout)
    }

    private func disclosureRow(_ item: PrivilegeDisclosure.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.callout.weight(.semibold))
            Text(item.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let code = item.code {
                Text(code)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var removalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Remove Fennec", symbol: "trash")
            // Concatenated strings are not literals, so SwiftUI will not parse
            // markdown in them; asterisks would render as asterisks.
            Text("Dragging Fennec to the Trash leaves the root helper registered with macOS. "
                 + "This removes it, along with everything else Fennec put on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Uninstall Fennec…") { showingUninstall = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                if helper.isRegistered {
                    Button("Remove Helper Only…") { confirmingHelperRemoval = true }
                        .tint(.red)
                        .help("Unregisters the root helper. Automatic repair stops, and turning it back on needs approval in System Settings again.")
                }
                Spacer()
            }
        }
    }

    // MARK: Uninstall

    private var uninstallSteps: [UninstallPlan.Step] {
        UninstallPlan.steps(
            // Registration, not reachability: a daemon awaiting approval is
            // registered, and dropping it from the plan produced "Fennec is
            // removed" over a root helper that was still there.
            helperInstalled: helper.isRegistered,
            loginItemRegistered: model.loginItemManager.state.isRegistered,
            keepLogs: keepLogs,
            canRemoveBundle: true,
            hasUpdateCache: FennecUpdater.hasUpdateCache
        )
    }

    private var uninstallSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(uninstaller.finished ? "Removal finished" : "Uninstall Fennec")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if uninstaller.finished {
                Text(uninstaller.allSucceeded
                     ? "Fennec is removed. Quitting…"
                     : (uninstaller.failureSummary ?? "Some steps did not complete."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !uninstaller.allSucceeded {
                    Text(UninstallPlan.manualFallback)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            } else {
                Text(UninstallPlan.summary(keepLogs: keepLogs, hasUpdateCache: FennecUpdater.hasUpdateCache))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(uninstallSteps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title).font(.callout.weight(.medium))
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Toggle("Keep my event log and repair history", isOn: $keepLogs)
                    .font(.callout)
            }

            HStack(spacing: 10) {
                if uninstaller.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Removing…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()

                if uninstaller.finished {
                    if !uninstaller.allSucceeded {
                        Button("Close") { showingUninstall = false }
                            .keyboardShortcut(.cancelAction)
                        if uninstaller.canRetry {
                            Button("Try Again") {
                                uninstaller.reset()
                            }
                        }
                    }
                } else {
                    Button("Cancel") { showingUninstall = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(uninstaller.isRunning)
                    Button("Uninstall") {
                        model.loginItemManager.refresh()
                        let steps = uninstallSteps
                        Task {
                            await uninstaller.run(keepLogs: keepLogs, steps: steps)
                            if uninstaller.allSucceeded { model.quit() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(uninstaller.isRunning)
                }
            }
        }
        .padding(22)
        .frame(width: 470)
    }

    // MARK: Details

    private static let verifyCommands = """
        shasum -a 256 -c Docs/SOURCE_MANIFEST.sha256
        codesign -dv --verbose=4 /Applications/Fennec.app
        codesign -dv --verbose=4 /Applications/Fennec.app/Contents/MacOS/FennecHelper
        """

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (build \(build))"
    }

    private var helperDescription: String {
        guard helper.state.isEnabled else { return "Not installed" }
        guard let identity = helper.identity else { return helper.state.title }
        return identity.description
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .accessibilityAddTraits(.isHeader)
    }
}
