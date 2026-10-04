import XCTest

/// Regressions from the adversarial IA / UX / macOS review.
///
/// Every test here corresponds to a finding that was confirmed against the
/// source. They are grouped by what the defect actually did to a user, because
/// that is the thing that must not come back.
final class ReviewRegressionTests: XCTestCase {

    // MARK: Blocker: uninstall could trash the app over a live root daemon

    func testAStagedHelperIsStillSomethingToRemove() {
        // `RepairHelperState.isEnabled` is false for `.awaitingApproval`, but
        // macOS holds a registration for it. Keying the plan off reachability
        // dropped the daemon step, trashed the app, and reported success.
        XCTAssertFalse(RepairHelperState.awaitingApproval.isEnabled)
        let steps = UninstallPlan.steps(
            helperInstalled: true, loginItemRegistered: false, keepLogs: true, canRemoveBundle: true
        )
        XCTAssertEqual(steps.first?.kind, .helper)
    }

    func testAnyUnfinishedRemovalStepKeepsTheAppAvailableForRetry() {
        let steps = UninstallPlan.steps(
            helperInstalled: true, loginItemRegistered: true, keepLogs: true, canRemoveBundle: true
        )
        let preceding = Array(steps.prefix { $0.kind != .bundle })
        let completed = Dictionary(uniqueKeysWithValues:
            preceding.map { ($0.kind, UninstallStepResult.done) })
        XCTAssertTrue(UninstallPlan.canRecycleBundle(steps: steps, results: completed))

        for step in preceding {
            var failed = completed
            failed[step.kind] = .failed("macOS refused")
            XCTAssertFalse(UninstallPlan.canRecycleBundle(steps: steps, results: failed),
                           "A failed \(step.kind.rawValue) step must leave the app available.")

            var missing = completed
            missing.removeValue(forKey: step.kind)
            XCTAssertFalse(UninstallPlan.canRecycleBundle(steps: steps, results: missing),
                           "An unreported \(step.kind.rawValue) step cannot count as removed.")
        }
    }

    @MainActor
    func testAPartialFailureCanBeRetried() async {
        let uninstaller = Uninstaller()
        await uninstaller.run(keepLogs: true, steps: [])
        uninstaller.reset()
        XCTAssertFalse(uninstaller.finished)
        XCTAssertTrue(uninstaller.results.isEmpty)
    }

    func testFailuresAreNamedByStepNotByEnumCase() {
        // "helper: …" is a developer's label. The user needs to know which
        // thing is still on their Mac.
        let steps = UninstallPlan.steps(
            helperInstalled: true, loginItemRegistered: true, keepLogs: false, canRemoveBundle: true
        )
        for step in steps {
            XCTAssertFalse(step.title.lowercased() == step.kind.rawValue.lowercased())
        }
    }

    // MARK: Major: the UI called a repair "fixed" from `succeeded` alone

    func testAReturnedRepairNeverGetsAGoldSeal() {
        // A gold checkmark directly above "Restarted, but the fault came back"
        // is one card asserting two opposite things.
        XCTAssertEqual(RepairOutcome.returned.symbolName, "arrow.uturn.backward.circle.fill")
        XCTAssertNotEqual(RepairOutcome.returned.symbolName, RepairOutcome.held.symbolName)
        XCTAssertNotEqual(FennecBrand.accent(for: .returned), FennecBrand.accent(for: .held))
    }

    func testOnlyAHeldRepairGetsTheGoldAccent() {
        XCTAssertEqual(FennecBrand.accent(for: .held), FennecBrand.gold)
        for outcome in [RepairOutcome.pending, .returned, .failed] {
            XCTAssertNotEqual(FennecBrand.accent(for: outcome), FennecBrand.gold)
        }
    }

    func testAPendingRepairIsNotCountedAsHeld() {
        let summary = RepairSummary.make(
            from: [
                Fixture.repair(at: Fixture.epoch, outcome: .pending),
                Fixture.repair(at: Fixture.epoch, outcome: .held),
                Fixture.repair(at: Fixture.epoch, outcome: .returned)
            ],
            now: Fixture.epoch
        )
        XCTAssertEqual(summary.held, 1, "Gold is spent on `held`, and only on `held`.")
        XCTAssertEqual(summary.successes, 2, "Restarts performed is a different number.")
        XCTAssertEqual(RepairCopy.headlineNumber(for: summary), "1")
    }

    // MARK: Major: the rehearsal was booked against the user as damage

    func testTheFirstRunTestRepairIsNotAnIncident() {
        let rehearsal = Fixture.repair(at: Fixture.epoch, trigger: .rehearsal)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let sign = DaysWithoutIncident.make(
            records: [rehearsal],
            listeningSince: Fixture.epoch.addingTimeInterval(-10 * 86_400),
            now: Fixture.epoch.addingTimeInterval(86_400),
            calendar: calendar
        )
        XCTAssertTrue(sign.isCleanRecord, "Nothing was wrong; the product asked them to press it.")
        XCTAssertEqual(sign.days, 11)
    }

    func testTheRehearsalIsNotCountedInTheLifetimeTally() {
        let summary = RepairSummary.make(
            from: [
                Fixture.repair(at: Fixture.epoch, trigger: .rehearsal, outcome: .held),
                Fixture.repair(at: Fixture.epoch, trigger: .automatic, outcome: .held)
            ],
            now: Fixture.epoch
        )
        XCTAssertEqual(summary.held, 1)
    }

    func testTheRehearsalIsStillLabelledInActivity() {
        XCTAssertEqual(RepairRecord.Trigger.rehearsal.title, "Test")
    }

    // MARK: Major: the helper's own rate limiter read as a failed repair

    func testTheThrottleReplyIsRecognisableAsARateLimiter() {
        let message = HelperThrottle.message(remainingSeconds: 14)
        XCTAssertTrue(HelperCallError(message: message).isThrottled)
        XCTAssertFalse(HelperCallError(message: "The repair helper did not respond.").isThrottled)
    }

    func testTheThrottleMarkerIsStrippedBeforeTheUserSeesIt() {
        let message = HelperThrottle.message(remainingSeconds: 14)
        let shown = HelperThrottle.userFacing(message)
        XCTAssertFalse(shown.contains(HelperThrottle.marker))
        XCTAssertTrue(shown.contains("14 seconds"))
        XCTAssertFalse(shown.contains("!"))
    }

    // MARK: Minor: a helper path with a space was printed as a shorter path

    func testAHelperPathContainingSpacesSurvivesParsing() {
        let reply = HelperIdentity.format(
            build: "7",
            path: "/Volumes/Work Drive/Fennec.app/Contents/MacOS/FennecHelper",
            euid: 0
        )
        let identity = HelperIdentity.parse(reply)
        XCTAssertEqual(identity.executablePath, "/Volumes/Work Drive/Fennec.app/Contents/MacOS/FennecHelper")
        XCTAssertEqual(identity.build, "7")
        XCTAssertEqual(identity.euid, 0)
    }

    // MARK: Minor: a repair left pending by a quit never counted

    @MainActor
    func testARepairLeftPendingByAQuitIsSettledOnNextLaunch() {
        let directory = Fixture.temporaryDirectory("stale-pending")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RepairHistoryStore(directory: directory)
        // Older than the verification window: Fennec was not running to see
        // whether the fault returned, so the machine gets the benefit of the
        // doubt rather than the record sitting unresolved forever.
        store.record(Fixture.repair(
            at: Date().addingTimeInterval(-RepairGovernor.verificationWindow - 30),
            outcome: .pending
        ))

        let reopened = RepairHistoryStore(directory: directory)
        XCTAssertEqual(reopened.records.first?.outcome, .held)
        XCTAssertNil(reopened.pendingVerification)
    }

    @MainActor
    func testARepairStillInsideItsWindowIsLeftAlone() {
        let directory = Fixture.temporaryDirectory("live-pending")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RepairHistoryStore(directory: directory)
        store.record(Fixture.repair(at: Date(), outcome: .pending))
        XCTAssertEqual(RepairHistoryStore(directory: directory).records.first?.outcome, .pending)
    }

    // MARK: Minor: the checklist implied automatic repair without the helper

    func testTheHelperStepSaysAutomaticRepairStopsWithoutIt() throws {
        let step = try XCTUnwrap(
            SetupChecklist.steps(helper: .notConfigured, loginItem: .enabled, notificationsAuthorized: true)
                .first { $0.kind == .helper }
        )
        XCTAssertTrue(step.detail.contains("asks before each repair"))
        XCTAssertTrue(step.compactDetail.contains("ask before repairing"))
    }
}
