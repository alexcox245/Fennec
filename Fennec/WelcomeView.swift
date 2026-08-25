import AppKit
import SwiftUI

/// First run.
///
/// Before this window existed, double-clicking Fennec produced nothing at all
/// — no window, no Dock icon, just one more glyph in a crowded menu bar. The
/// people who noticed deleted it; the people who did not were approving root
/// access on faith.
///
/// So this is deliberately not a welcome tour. It is a consent record. It
/// states the complete privileged surface before asking for any of it, it
/// costs the repair in plain seconds, and it ends with a real repair the user
/// runs on purpose while nothing is at stake — because nobody who cares about
/// their audio will let a background process interrupt their output device
/// without first hearing what that interruption sounds like on their own rig.
///
/// It reads top to bottom as one argument: **what Fennec does**, then what
/// that costs this Mac, then **what it needs from you** — in that order,
/// because a permission request that arrives before the mechanism is just a
/// toll. By the time the window reaches that last section, two of the three
/// permissions are already on: Fennec granted itself the ones that raise no
/// dialog (`AppModel.applyFirstRunDefaults`), says so in the row, and puts the
/// switch to undo it in the same line. What is left is the administrator
/// password, which is the one thing on this screen that is genuinely a request.
///
/// What it deliberately does *not* do is play a test tone. Fennec does not
/// know the user's monitor gain, and pushing a sine wave through open-back
/// headphones at whatever level the last session left them is a hearing risk.
struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var helper: HelperManager
    @ObservedObject private var loginItem: LoginItemManager
    @ObservedObject private var history: RepairHistoryStore

    private let location = InstallLocation.current()

    init(model: AppModel) {
        self.model = model
        _helper = ObservedObject(wrappedValue: model.helperManager)
        _loginItem = ObservedObject(wrappedValue: model.loginItemManager)
        _history = ObservedObject(wrappedValue: model.repairHistory)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    masthead
                    if location.warning != nil { locationNotice }
                    whatItDoes
                    disclosure
                    permissions
                    rehearsal
                    whereToFindIt
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 30)
            }

            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 640)
        .fennecConfirmation(model)
        .task { model.refreshAll() }
    }

    // MARK: Sections

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Image("FennecMascot")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Fennec")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Catches Core Audio crackling and restarts it before you have to.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            needs
        }
    }

    /// The answer to "what is this going to ask me for", above the fold and
    /// before a single button. The three permissions never change; which of
    /// them are already handled does, so the second line is derived from live
    /// state rather than written down as an assumption.
    private var needs: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(SetupChecklist.whatItNeeds)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.firstRunStatus)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tinted rather than another neutral card. Three stacked panels in the
        // same grey read as three equal blocks of small print; this one is the
        // orienting statement, and the reader has to be able to tell.
        .background(FennecBrand.sky.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FennecBrand.sky.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
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
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .layoutPriority(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.dune.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(FennecBrand.dune.opacity(0.3), lineWidth: 1)
        }
    }

    /// Mechanism first. Someone who has just double-clicked an unfamiliar app
    /// that is about to want root is asking "what is this", and every answer
    /// that starts with a permission has skipped the question.
    private var whatItDoes: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("What Fennec does", symbol: "eye")

            VStack(alignment: .leading, spacing: 14) {
                ForEach(PrivilegeDisclosure.whatItDoes) { item in
                    disclosureRow(item)
                }
            }

            Text(PrivilegeDisclosure.whyNotAShellAlias)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(FennecBrand.cardStroke, lineWidth: 1)
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("What Fennec will do to this Mac", symbol: "lock.shield")

            VStack(alignment: .leading, spacing: 14) {
                ForEach(PrivilegeDisclosure.privilegedActions) { item in
                    disclosureRow(item)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                ForEach(PrivilegeDisclosure.facts) { item in
                    disclosureRow(item)
                }
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

    private func disclosureRow(_ item: PrivilegeDisclosure.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.callout.weight(.semibold))
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

    /// Every permission Fennec uses, in one place, each one saying who granted
    /// it. Two of them Fennec granted itself at launch; the row says so and
    /// carries the switch to take it back, because a default that is hard to
    /// find is not a default, it is a helping of yourself.
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("What Fennec needs from you", symbol: "key")
            Text(model.setupSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(model.setupSteps) { step in
                    permissionRow(step)
                }
            }

            if let error = helper.lastError ?? loginItem.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(_ step: SetupStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The administrator step is the only prominent button on the
            // window. Three identical bordered buttons tell a new user nothing
            // about which one is the actual request.
            SetupStepRow(
                step: step,
                compact: false,
                isPrimary: step.grant == .administrator && !step.isComplete
            ) {
                model.performSetupAction(for: step)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.grant.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if step.kind == .loginItem && step.isComplete {
                    // The undo, in the same line as the claim. Settings has the
                    // same switch, but a person reading "Fennec turned this on
                    // for you" should not have to go looking for it.
                    Button("Turn Off") { loginItem.setEnabled(false) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .layoutPriority(1)
                }
            }
            .padding(.leading, 25)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(FennecBrand.cardStroke, lineWidth: 1)
        }
    }

    private var rehearsal: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Try it once, now", symbol: "play.circle")
            Text("Run a repair while nothing is at stake, so you know exactly what one costs. "
                 + "Audio stops for about a second and every app stays open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    // A rehearsal, not a repair: nothing was wrong, so it must
                    // not reset the days-without-incident sign or be counted
                    // as damage in the lifetime tally.
                    model.requestRehearsalRepair()
                } label: {
                    Label(testButtonTitle, systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(FennecBrand.sky)
                .disabled(model.isRepairing || model.isPreparingRepair)

                if model.isRepairing || model.isPreparingRepair {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if let repair = testRepair {
                testResult(repair)
            }
        }
    }

    private var testButtonTitle: String {
        if model.isRepairing { return "Restarting Core Audio…" }
        if model.isPreparingRepair { return "Checking what is using audio…" }
        return "Run a Test Repair"
    }

    /// Only the repair this window asked for. Reopening the window from the
    /// Help menu or the stand-down card used to show the newest record of any
    /// kind — captioned "That is what an automatic repair will cost you."
    private var testRepair: RepairRecord? {
        guard let id = model.lastRepairID else { return nil }
        return history.records.first { $0.id == id }
    }

    private func testResult(_ repair: RepairRecord) -> some View {
        let accent = FennecBrand.accent(for: repair.outcome)
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: repair.outcome.symbolName)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(RepairCopy.receiptHeadline(for: repair))
                    .font(.callout.weight(.semibold))
                Text(repair.succeeded
                     ? "That is what an automatic repair will cost you."
                     : RepairCopy.receiptDetail(for: repair))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var whereToFindIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Where Fennec lives", symbol: "menubar.arrow.up.rectangle")

            HStack(spacing: 12) {
                // The real glyph, not a description of it. If a menu-bar
                // manager has swallowed the app, this is what to look for.
                Image(nsImage: MenuBarIcon.image(for: .listening, size: CGSize(width: 22, height: 22)))
                    .accessibilityHidden(true)
                Text("This mark, near the clock. Click it for status, the repair button, and Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            DisclosureGroup("Not seeing it in the menu bar?") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PrivilegeDisclosure.missingFromMenuBar) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.callout.weight(.medium))
                            Text(item.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 10)
            }
            .font(.callout)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.isFullySetUp
                 ? "Fennec is listening. You can close this."
                 : "You can finish this later from the menu bar. Nothing here expires.")
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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .accessibilityAddTraits(.isHeader)
    }
}
