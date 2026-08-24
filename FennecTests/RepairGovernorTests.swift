import XCTest

/// The loop this prevents: on a Mac where the restart is not the cure — a
/// failing cable, a marginal interface, a buffer size the machine cannot meet
/// — Fennec detects, restarts, claims success, waits out the cooldown, and
/// detects again. Forever. Every 45 seconds, silencing all audio each time.
final class RepairGovernorTests: XCTestCase {
    private let now = Fixture.epoch

    private func repairs(
        _ outcomes: [RepairOutcome],
        spacing: TimeInterval = 60,
        trigger: RepairRecord.Trigger = .automatic,
        device: String = "MacBook Pro Speakers"
    ) -> [RepairRecord] {
        // Newest first, as RepairHistoryStore keeps them.
        outcomes.enumerated().map { index, outcome in
            Fixture.repair(
                at: now.addingTimeInterval(-Double(index) * spacing),
                trigger: trigger,
                device: device,
                succeeded: outcome != .failed,
                outcome: outcome
            )
        }
    }

    // MARK: Not standing down

    func testAQuietHistoryDoesNotStandDown() {
        XCTAssertNil(RepairGovernor.standDown(records: [], now: now))
        XCTAssertNil(RepairGovernor.standDown(records: repairs([.held, .held, .held]), now: now))
    }

    func testTwoFailuresAreNotYetAPattern() {
        XCTAssertNil(RepairGovernor.standDown(records: repairs([.returned, .returned]), now: now))
    }

    func testRepairsThatHeldDoNotCount() {
        XCTAssertNil(
            RepairGovernor.standDown(records: repairs([.returned, .held, .returned, .held]), now: now),
            "A machine that mostly recovers is not a machine to give up on."
        )
    }

    func testOldFailuresFallOutOfTheWindow() {
        // Three failures, but spread over an hour — a bad afternoon, not a
        // machine that cannot be fixed by a restart.
        let spread = repairs([.returned, .returned, .returned], spacing: 15 * 60)
        XCTAssertNil(RepairGovernor.standDown(records: spread, now: now))
    }

    func testManualRepairsNeverTriggerAStandDown() {
        let manual = repairs([.returned, .returned, .returned], trigger: .manual)
        XCTAssertNil(
            RepairGovernor.standDown(records: manual, now: now),
            "Someone who pressed the button three times has decided three times."
        )
    }

    // MARK: Standing down

    func testThreeReturnsInsideTheWindowStandDown() throws {
        let standDown = try XCTUnwrap(RepairGovernor.standDown(records: repairs([.returned, .returned, .returned]), now: now))
        XCTAssertEqual(standDown.attempts, 3)
        XCTAssertEqual(standDown.until, now.addingTimeInterval(RepairGovernor.standDownDuration))
        XCTAssertTrue(standDown.isActive(at: now))
    }

    func testOutrightFailuresCountToo() throws {
        // A helper that will not answer is as unhelpful as a restart that
        // does not hold, and it loops just as fast.
        let standDown = try XCTUnwrap(RepairGovernor.standDown(records: repairs([.failed, .failed, .failed]), now: now))
        XCTAssertEqual(standDown.attempts, 3)
    }

    func testAMixOfReturnedAndFailedCounts() throws {
        let standDown = try XCTUnwrap(RepairGovernor.standDown(records: repairs([.failed, .returned, .failed]), now: now))
        XCTAssertEqual(standDown.attempts, 3)
    }

    func testItExpiresOnItsOwn() throws {
        let standDown = try XCTUnwrap(RepairGovernor.standDown(records: repairs([.returned, .returned, .returned]), now: now))
        XCTAssertFalse(standDown.isActive(at: now.addingTimeInterval(RepairGovernor.standDownDuration + 1)))
        XCTAssertNil(standDown.remaining(at: now.addingTimeInterval(RepairGovernor.standDownDuration + 1)))
    }

    func testAnAlreadyExpiredRunProducesNothing() {
        let ancient = repairs([.returned, .returned, .returned]).map { record in
            Fixture.repair(
                at: record.date.addingTimeInterval(-RepairGovernor.standDownDuration - 60),
                trigger: .automatic,
                succeeded: false,
                outcome: .returned
            )
        }
        XCTAssertNil(RepairGovernor.standDown(records: ancient, now: now))
    }

    // MARK: What it says

    func testTheReasonNamesTheNumbersAndTheDevice() throws {
        let standDown = try XCTUnwrap(RepairGovernor.standDown(
            records: repairs([.returned, .returned, .returned], spacing: 120, device: "Fireface UCX II"),
            now: now
        ))
        let reason = standDown.reason
        XCTAssertTrue(reason.hasPrefix("3 restarts in "), reason)
        XCTAssertTrue(reason.contains("Fireface UCX II"), reason)
        XCTAssertTrue(
            reason.contains("not fixing this"),
            "The user has to be told the restart is not the cure — that is the whole point."
        )
        XCTAssertFalse(reason.contains("!"))
        XCTAssertFalse(reason.lowercased().contains("sorry"))
    }

    func testTheReasonReportsTheRealSpan() throws {
        let standDown = try XCTUnwrap(RepairGovernor.standDown(
            records: repairs([.returned, .returned, .returned], spacing: 120),
            now: now
        ))
        XCTAssertEqual(standDown.elapsedSeconds, 240, accuracy: 0.001)
        XCTAssertTrue(standDown.reason.contains("240 s"), standDown.reason)
    }

    // MARK: Verification window

    func testTheVerificationDeadlineIsAMinuteOut() {
        XCTAssertEqual(RepairGovernor.verificationDeadline(after: now), now.addingTimeInterval(60))
        XCTAssertEqual(RepairGovernor.verificationWindow, 60)
    }
}

/// A repair is provisional until the fault fails to return, and the copy has
/// to say so — the instant a repair finishes, the only established fact is
/// that a new `coreaudiod` process exists.
final class RepairOutcomeCopyTests: XCTestCase {
    private func record(_ outcome: RepairOutcome, trigger: RepairRecord.Trigger = .automatic) -> RepairRecord {
        Fixture.repair(
            at: Fixture.epoch,
            trigger: trigger,
            duration: 0.84,
            succeeded: outcome != .failed,
            outcome: outcome
        )
    }

    func testAPendingRepairDoesNotClaimVictory() {
        let headline = RepairCopy.receiptHeadline(for: record(.pending))
        XCTAssertEqual(headline, "Restarted in 0.84 s · watching")
        XCTAssertFalse(headline.contains("fixed"))
    }

    func testOnlyAHeldRepairIsCalledFixed() {
        XCTAssertEqual(RepairCopy.receiptHeadline(for: record(.held)), "Caught and fixed in 0.84 s")
    }

    func testAReturnedFaultSaysSoPlainly() {
        XCTAssertEqual(RepairCopy.receiptHeadline(for: record(.returned)), "Restarted, but the fault came back")
        XCTAssertTrue(RepairCopy.receiptDetail(for: record(.returned)).contains("did not clear it"))
    }

    func testTheCorrectionBannerNamesTheDeviceAndTheImplication() {
        let body = RepairCopy.faultReturnedBody(for: record(.returned))
        XCTAssertTrue(body.contains("MacBook Pro Speakers"))
        XCTAssertTrue(body.contains("not the cure"))
        XCTAssertFalse(body.contains("!"))
    }

    func testAManualRepairThatHeldIsNotCreditedToFennec() {
        XCTAssertEqual(RepairCopy.receiptHeadline(for: record(.held, trigger: .manual)), "Restarted in 0.84 s")
    }

    func testNoOutcomeProducesEmptyOrShoutingCopy() {
        for outcome in [RepairOutcome.pending, .held, .returned, .failed] {
            let sample = record(outcome)
            XCTAssertFalse(RepairCopy.receiptHeadline(for: sample).isEmpty)
            XCTAssertFalse(RepairCopy.receiptDetail(for: sample).isEmpty)
            XCTAssertFalse(RepairCopy.receiptHeadline(for: sample).contains("!"))
        }
    }

    @MainActor
    func testTheHeadlineCountExcludesRepairsThatDidNotHold() {
        let directory = Fixture.temporaryDirectory("outcome-summary")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RepairHistoryStore(directory: directory)
        store.record(Fixture.repair(at: Fixture.epoch, outcome: .held))
        store.record(Fixture.repair(at: Fixture.epoch.addingTimeInterval(1), outcome: .returned))
        store.record(Fixture.repair(at: Fixture.epoch.addingTimeInterval(2), succeeded: false, outcome: .failed))

        XCTAssertEqual(
            RepairCopy.headlineNumber(for: store.summary), "1",
            "The tally is a claim about how much Fennec helped, not how broken the Mac is."
        )
    }

    @MainActor
    func testAnOutcomeCanBeSettledAfterTheFact() {
        let directory = Fixture.temporaryDirectory("outcome-update")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RepairHistoryStore(directory: directory)
        let repair = Fixture.repair(at: Fixture.epoch, outcome: .pending)
        store.record(repair)
        XCTAssertNotNil(store.pendingVerification)

        store.setOutcome(.held, for: repair.id)
        XCTAssertNil(store.pendingVerification)
        XCTAssertEqual(store.records.first?.outcome, .held)
        XCTAssertEqual(RepairHistoryStore(directory: directory).records.first?.outcome, .held)
    }

    @MainActor
    func testARecordWrittenBeforeOutcomesExistedStillDecodes() throws {
        let directory = Fixture.temporaryDirectory("outcome-legacy")
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacy = """
            [{"date":"2027-01-15T09:00:00Z","deviceName":"MacBook Pro Speakers","durationSeconds":0.84,\
            "elapsedSeconds":5.8,"id":"\(UUID().uuidString)","message":"Core Audio restarted successfully.",\
            "signal":"processorOverload","signalCount":2,"succeeded":true,"transport":"builtIn","trigger":"automatic"}]
            """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent(AppConstants.repairHistoryFileName))

        let store = RepairHistoryStore(directory: directory)
        XCTAssertNil(store.lastError, "A file from an older build must not read as corrupt.")
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.outcome, .held)
    }
}
