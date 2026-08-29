import AppKit
import SwiftUI

/// First run.
///
/// Before this window existed, double-clicking Fennec produced nothing at
/// all: no window, no Dock icon, just one more glyph in a crowded menu bar. The
/// people who noticed deleted it; the people who did not were approving root
/// access on faith.
///
/// So this is deliberately not a welcome tour. It is a consent record. It
/// states the complete privileged surface before asking for any of it, it
/// costs the repair in plain seconds, and it ends with a real repair the user
/// runs on purpose while nothing is at stake, because nobody who cares about
/// their audio will let a background process interrupt their output device
/// without first hearing what that interruption sounds like on their own rig.
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
                    disclosure
                    setup
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
                    Text("Catches crackling and fixes it before you have to.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text(PrivilegeDisclosure.whyNotAShellAlias)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FennecBrand.dune.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(FennecBrand.dune.opacity(0.3), lineWidth: 1)
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

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Set it up", symbol: "checklist")
            Text(model.setupSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                ForEach(model.setupSteps) { step in
                    SetupStepRow(step: step, compact: false) {
                        model.performSetupAction(for: step)
                    }
                }
            }

            if !model.isFullySetUp {
                dragWell
            }

            if let error = helper.lastError ?? loginItem.lastError ?? model.installError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The Clicky move: hand the user the app icon right where the
    /// instructions are, so "find the app" is a drag, not a Finder safari.
    /// The Open at Login list in System Settings takes the drop directly, and
    /// so does the Applications folder.
    private var dragWell: some View {
        HStack(alignment: .center, spacing: 14) {
            DraggableAppIcon()
            VStack(alignment: .leading, spacing: 4) {
                Text("When a list wants the app itself, drag this.")
                    .font(.callout.weight(.semibold))
                Text("The Open at Login list in System Settings accepts the drop, and so does "
                     + "your Applications folder. It is the same Fennec.app wherever it lands. "
                     + "When every step above is done, press Done and Fennec fades into the "
                     + "menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
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
        if model.isRepairing { return "Repairing…" }
        if model.isPreparingRepair { return "Checking what is using audio…" }
        return "Run a Test Repair"
    }

    /// Only the repair this window asked for. Reopening the window from the
    /// Help menu or the stand-down card used to show the newest record of any
    /// kind, captioned "That is what an automatic repair will cost you."
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
                 : "You can finish setup later from the menu bar.")
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
