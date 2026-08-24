import AppKit
import SwiftUI

/// About, but useful.
///
/// The standard macOS About panel shows a version number and a copyright
/// line. For a 3 MB app from an unknown developer that installs a root
/// LaunchDaemon, that is not the information anyone actually wants. This one
/// answers the four questions a person evaluating that decision asks:
///
/// 1. What can it do to my Mac? (all three privileged paths, verbatim)
/// 2. What is *actually* running as root right now? (the helper's own build
///    and path, read back over XPC — because after an in-place update the app
///    and the daemon can disagree)
/// 3. Can I check the code matches the binary? (the source manifest, which is
///    the strongest thing this repo has and was mentioned nowhere a user
///    would look)
/// 4. Can I get rid of it? (completely, including the daemon)
struct AboutView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var helper: HelperManager
    @StateObject private var uninstaller = Uninstaller()

    @State private var showingUninstall = false
    @State private var confirmingHelperRemoval = false
    @State private var keepLogs = true
    @State private var copiedCommands = false

    init(model: AppModel) {
        self.model = model
        _helper = ObservedObject(wrappedValue: model.helperManager)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead
                privilegeSection
                verifySection
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
            Text("Automatic repair stops immediately. Turning it back on needs your approval in System Settings again. Repair Audio Now will still work, using your administrator password.")
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
                Text(PrivilegeDisclosure.whyNotAShellAlias)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var privilegeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("What Fennec can do to this Mac", symbol: "lock.shield")

            ForEach(PrivilegeDisclosure.privilegedActions) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.callout.weight(.semibold))
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let code = item.code {
                        Text(code)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .accessibilityElement(children: .combine)
            }

            Divider()

            // LabeledContent only spreads inside a Form; here it would render
            // the label and value jammed together on the left.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Helper running as root")
                    .font(.callout)
                Spacer(minLength: 12)
                Text(helperDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if let mismatch = helper.versionMismatch {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(FennecBrand.dune)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(FennecBrand.cardStroke, lineWidth: 1)
        }
    }

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Check this build", symbol: "checkmark.seal")
            Text("Fennec ships a SHA-256 of every source file it was built from. "
                 + "These three commands say whether the code you can read is the code that is running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(Self.verifyCommands)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                Button(copiedCommands ? "Copied" : "Copy Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.verifyCommands, forType: .string)
                    // A button that writes the pasteboard and changes nothing
                    // is indistinguishable from one that did not work.
                    copiedCommands = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1_500))
                        copiedCommands = false
                    }
                }
                .disabled(copiedCommands)
                .help("Copies the three verification commands to the clipboard.")
                Button("Reveal Event Log") { model.openEventLog() }
                    .help("The raw JSONL stream Fennec writes: every signal, every skipped repair, every device change.")
                Spacer()
            }
        }
    }

    private var removalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Remove Fennec", symbol: "trash")
            // Concatenated strings are not literals, so SwiftUI will not parse
            // markdown in them — asterisks would render as asterisks.
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
            loginItemEnabled: model.loginItemManager.isEnabled,
            keepLogs: keepLogs,
            canRemoveBundle: true
        )
    }

    private var uninstallSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(uninstaller.finished ? "Removal finished" : "Uninstall Fennec")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if uninstaller.finished {
                Text(uninstaller.allSucceeded
                     ? "Fennec is removed. Quit to finish."
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
                Text(UninstallPlan.summary(keepLogs: keepLogs))
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
                    // Always an exit. A sheet whose only control is "Quit" is
                    // a dead end for anyone reading a partial-failure report.
                    Button("Close") { showingUninstall = false }
                        .keyboardShortcut(.cancelAction)
                    if !uninstaller.allSucceeded && uninstaller.canRetry {
                        Button("Try Again") {
                            uninstaller.reset()
                        }
                    }
                    Button("Quit Fennec") { model.quit() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { showingUninstall = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(uninstaller.isRunning)
                    Button("Uninstall") {
                        let steps = uninstallSteps
                        Task { await uninstaller.run(keepLogs: keepLogs, steps: steps) }
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
        return "Version \(version) (build \(build)) · local only, no network"
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
