import XCTest

/// These assertions are unusually literal on purpose. `RepairCopy` produces
/// the only sentences most users will ever read from Fennec, and AGENTS.md §7
/// makes the register a product requirement: state the mechanism, name the
/// threshold, no exclamation marks, no emoji, no apologising. A test that
/// pins the exact string is the cheapest way to keep that from eroding.
final class RepairCopyTests: XCTestCase {

    // MARK: Durations

    func testSubSecondDurationsKeepTwoDecimals() {
        XCTAssertEqual(RepairCopy.duration(0.84), "0.84 s")
        XCTAssertEqual(RepairCopy.duration(0.006), "0.01 s")
    }

    func testSingleDigitSecondsKeepOneDecimal() {
        XCTAssertEqual(RepairCopy.duration(1.24), "1.2 s")
        XCTAssertEqual(RepairCopy.duration(9.96), "10.0 s")
    }

    func testLongDurationsDropDecimals() {
        XCTAssertEqual(RepairCopy.duration(12.4), "12 s")
        XCTAssertEqual(RepairCopy.duration(180), "180 s")
    }

    func testNonsenseDurationsRenderAsADash() {
        XCTAssertEqual(RepairCopy.duration(-1), "—")
        XCTAssertEqual(RepairCopy.duration(.nan), "—")
        XCTAssertEqual(RepairCopy.duration(.infinity), "—")
    }

    // MARK: The cause clause

    func testOverloadCauseNamesTheCountTheSpanAndTheDevice() {
        let record = Fixture.repair(
            at: Fixture.epoch,
            signal: .processorOverload,
            signalCount: 2,
            elapsed: 5.8,
            device: "MacBook Pro Speakers"
        )
        XCTAssertEqual(
            RepairCopy.cause(for: record),
            "Repeated crackling on MacBook Pro Speakers.",
            "The count and the span are in the event log. The user heard crackling."
        )
    }

    func testSignalsInsideOneDrainAreDescribedAsBackToBack() {
        let record = Fixture.repair(
            at: Fixture.epoch,
            signal: .processorOverload,
            signalCount: 3,
            elapsed: 0,
            device: "MacBook Pro Speakers"
        )
        XCTAssertEqual(
            RepairCopy.cause(for: record),
            "Repeated crackling on MacBook Pro Speakers.",
            "Two signals or ten, back to back or spread out: the user heard it more than once."
        )
    }

    func testASingleSignalIsNotPluralised() {
        let record = Fixture.repair(
            at: Fixture.epoch,
            signal: .processorOverload,
            signalCount: 1,
            device: "Studio Display Speakers"
        )
        XCTAssertEqual(RepairCopy.cause(for: record), "Crackling on Studio Display Speakers.")
    }

    func testAbnormalStopHasItsOwnCause() {
        let record = Fixture.repair(at: Fixture.epoch, signal: .ioStoppedAbnormally, signalCount: 1)
        XCTAssertEqual(
            RepairCopy.cause(for: record),
            "Sound cut out on MacBook Pro Speakers.",
            "A dropout is not a crackle, and the user can tell the difference by ear."
        )
    }

    func testManualRepairsHaveNoSignalToBlame() {
        let record = Fixture.repair(at: Fixture.epoch, trigger: .manual, signal: nil, signalCount: 0)
        XCTAssertEqual(RepairCopy.cause(for: record), "You asked for a reset on MacBook Pro Speakers.")
    }

    func testAMissingDeviceNameStillProducesAReadableSentence() {
        let record = Fixture.repair(at: Fixture.epoch, signal: .processorOverload, signalCount: 2, elapsed: 3, device: "")
        XCTAssertEqual(RepairCopy.cause(for: record), "Repeated crackling on your speakers.")
    }

    // MARK: Notifications (the headline moment)

    func testAutomaticSuccessSaysCrackleResolved() {
        let record = Fixture.repair(
            at: Fixture.epoch,
            trigger: .automatic,
            signal: .processorOverload,
            signalCount: 2,
            elapsed: 5.8,
            duration: 0.84
        )
        XCTAssertEqual(RepairCopy.notificationTitle(for: record), "Audio repaired")
        XCTAssertEqual(
            RepairCopy.notificationBody(for: record),
            "",
            "Title only. The title already says the one thing the user wanted to know."
        )
    }

    /// The heads-up posted the moment the automatic path commits. Two short
    /// clauses and nothing else; the user is mid-fault and mid-task.
    func testRepairStartingCopyIsTerse() {
        XCTAssertEqual(RepairCopy.repairStartingTitle(), "Crackle detected")
        XCTAssertEqual(RepairCopy.repairStartingBody(), "Resetting speakers...")
        XCTAssertFalse(RepairCopy.repairStartingTitle().contains("!"))
        XCTAssertFalse(RepairCopy.repairStartingBody().contains("!"))
    }

    /// The retraction that replaces the heads-up when the safety scan says
    /// no. It must exist, because "Resetting speakers..." followed by
    /// silence is a promise the product broke.
    func testRepairCalledOffCopyNamesTheSkip() {
        XCTAssertEqual(RepairCopy.repairCalledOffTitle(), "Crackle repair skipped")
        XCTAssertFalse(RepairCopy.repairCalledOffTitle().contains("!"))
    }

    /// Automatic and manual now read identically. Which one it was is
    /// Fennec's business, not news to the person whose audio just came back.
    func testEverySuccessfulRepairGetsTheSameLine() {
        let manual = Fixture.repair(at: Fixture.epoch, trigger: .manual, signal: nil, signalCount: 0, duration: 1.1)
        let automatic = Fixture.repair(at: Fixture.epoch, trigger: .automatic, signal: .processorOverload, signalCount: 2, duration: 0.4)
        XCTAssertEqual(RepairCopy.notificationTitle(for: manual), "Audio repaired")
        XCTAssertEqual(RepairCopy.notificationTitle(for: automatic), "Audio repaired")
        XCTAssertEqual(RepairCopy.notificationBody(for: manual), "")
        XCTAssertEqual(RepairCopy.notificationBody(for: automatic), "")
    }

    func testFailureLeadsWithTheProblemAndCarriesTheRealError() {
        let record = Fixture.repair(
            at: Fixture.epoch,
            signal: .processorOverload,
            signalCount: 2,
            elapsed: 4,
            succeeded: false,
            message: "The repair helper did not respond within 5 seconds."
        )
        XCTAssertEqual(RepairCopy.notificationTitle(for: record), "Fennec could not fix the crackle")
        XCTAssertTrue(
            RepairCopy.notificationBody(for: record).hasSuffix("did not respond within 5 seconds."),
            "A failure keeps its body: this is the case with something left to do."
        )
    }

    // MARK: Voice

    func testNoCopyShoutsOrUsesEmoji() {
        let samples: [RepairRecord] = [
            Fixture.repair(at: Fixture.epoch, trigger: .automatic, signal: .processorOverload, signalCount: 2, elapsed: 5.8),
            Fixture.repair(at: Fixture.epoch, trigger: .manual, signal: nil, signalCount: 0),
            Fixture.repair(at: Fixture.epoch, signal: .ioStoppedAbnormally, signalCount: 1),
            Fixture.repair(at: Fixture.epoch, succeeded: false, message: "The repair timed out.")
        ]

        for record in samples {
            let strings = [
                RepairCopy.notificationTitle(for: record),
                RepairCopy.notificationBody(for: record),
                RepairCopy.receiptHeadline(for: record),
                RepairCopy.receiptDetail(for: record)
            ]
            for string in strings {
                XCTAssertFalse(string.contains("!"), "Fennec does not exclaim: \(string)")
                XCTAssertFalse(
                    string.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C },
                    "Fennec does not use emoji in product UI: \(string)"
                )
            }
            // Everything except a successful notification body, which is
            // deliberately empty: the title is the whole message (T-043).
            XCTAssertFalse(RepairCopy.notificationTitle(for: record).isEmpty)
            XCTAssertFalse(RepairCopy.receiptHeadline(for: record).isEmpty)
            XCTAssertFalse(RepairCopy.receiptDetail(for: record).isEmpty)
            if !record.succeeded {
                XCTAssertFalse(RepairCopy.notificationBody(for: record).isEmpty)
            }
        }
    }

    // MARK: One sentence for one outcome (T-044)

    /// The banner, the button, and the manual receipt can all report the
    /// same repair within seconds of each other: the notification arrives
    /// while the button the user just pressed is still on screen, and
    /// Activity has a row for it. Three phrasings for one event reads as
    /// three events, so they share a single string.
    func testEverySurfaceReportsASuccessInTheSameWords() {
        let manual = Fixture.repair(at: Fixture.epoch, trigger: .manual, duration: 0.84, outcome: .held)
        XCTAssertEqual(RepairCopy.notificationTitle(for: manual), RepairCopy.repairedTitle)
        XCTAssertEqual(RepairCopy.primaryButtonTitle(for: .repaired), RepairCopy.repairedTitle)
        XCTAssertEqual(RepairCopy.receiptHeadline(for: manual), RepairCopy.repairedTitle)
        XCTAssertEqual(RepairCopy.repairedTitle, "Audio repaired")
    }

    // MARK: The plain-language rule (T-043)

    /// The owner's directive, pinned: nobody installs this because they know
    /// what Core Audio is. Every string a banner or a popover can show is
    /// checked, across every record shape.
    func testNoUserFacingCopyNamesCoreAudioOrATiming() {
        let samples: [RepairRecord] = [
            Fixture.repair(at: Fixture.epoch, trigger: .automatic, signal: .processorOverload, signalCount: 2, elapsed: 5.8, duration: 0.84),
            Fixture.repair(at: Fixture.epoch, trigger: .manual, signal: nil, signalCount: 0, duration: 1.1),
            Fixture.repair(at: Fixture.epoch, signal: .ioStoppedAbnormally, signalCount: 1),
            Fixture.repair(at: Fixture.epoch, succeeded: false, message: "The repair timed out.")
        ]

        var strings = RepairCopy.PrimaryPhase.allCases.map { RepairCopy.primaryButtonTitle(for: $0) }
        strings += [
            RepairCopy.repairStartingTitle(),
            RepairCopy.repairStartingBody(),
            RepairCopy.repairCalledOffTitle(),
            RepairCopy.stallAdvisoryTitle(),
            RepairCopy.foxSection, RepairCopy.foxSetting, RepairCopy.foxPreview, RepairCopy.foxPreviewHelp,
            RepairCopy.foxDetail, RepairCopy.foxReducedMotion
        ]
        for record in samples {
            strings += [
                RepairCopy.notificationTitle(for: record),
                RepairCopy.notificationBody(for: record),
                RepairCopy.receiptHeadline(for: record),
                RepairCopy.receiptDetail(for: record),
                RepairCopy.cause(for: record),
                RepairCopy.outcome(for: record),
                RepairCopy.faultReturnedTitle(for: record),
                RepairCopy.faultReturnedBody(for: record)
            ]
        }

        for string in strings {
            XCTAssertFalse(
                string.lowercased().contains("core audio"),
                "No user-facing string may say Core Audio: \(string)"
            )
            XCTAssertFalse(
                string.contains(" s.") || string.contains(" s "),
                "No user-facing string may carry a timing: \(string)"
            )
        }
    }

    // MARK: The primary button

    func testTheButtonOffersTheActionBeforeItIsPressed() {
        XCTAssertEqual(RepairCopy.primaryButtonTitle(for: .idle), "Repair Audio Now")
        XCTAssertEqual(RepairCopy.primaryButtonSymbol(for: .idle), "wrench.and.screwdriver.fill")
    }

    /// One sentence for both halves of the work. The safety scan and the
    /// restart are Fennec's internals, not the user's problem.
    func testTheButtonSaysOneThingWhileItWorks() {
        XCTAssertEqual(RepairCopy.primaryButtonTitle(for: .working), "Repairing\u{2026}")
        XCTAssertEqual(RepairCopy.primaryButtonSymbol(for: .working), "wrench.and.screwdriver.fill")
    }

    func testTheButtonConfirmsWithACheckMark() {
        XCTAssertEqual(RepairCopy.primaryButtonTitle(for: .repaired), "Audio repaired")
        XCTAssertEqual(RepairCopy.primaryButtonSymbol(for: .repaired), "checkmark.circle.fill")
    }

    /// The check mark belongs to exactly one phase. A tick beside
    /// "Repairing\u{2026}" would be a lie for as long as it was on screen.
    func testOnlyTheResultPhaseWearsTheCheckMark() {
        let ticked = RepairCopy.PrimaryPhase.allCases.filter {
            RepairCopy.primaryButtonSymbol(for: $0).hasPrefix("checkmark")
        }
        XCTAssertEqual(ticked, [.repaired])
    }

    func testEveryButtonPhaseHasDistinctNonEmptyCopy() {
        let titles = RepairCopy.PrimaryPhase.allCases.map { RepairCopy.primaryButtonTitle(for: $0) }
        XCTAssertEqual(Set(titles).count, titles.count, "Two phases share a title: \(titles)")
        for title in titles {
            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(title.contains("!"), "Fennec does not exclaim: \(title)")
            XCTAssertFalse(
                title.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C },
                "Fennec does not use emoji in product UI: \(title)"
            )
        }
    }

    // MARK: Receipts and totals

    func testTheAutomaticReceiptSaysFennecCaughtIt() {
        let record = Fixture.repair(at: Fixture.epoch, trigger: .automatic, duration: 0.84)
        XCTAssertEqual(RepairCopy.receiptHeadline(for: record), "Caught and fixed")
    }

    func testManualReceiptIsWordedDifferently() {
        let record = Fixture.repair(at: Fixture.epoch, trigger: .manual, duration: 1.5)
        XCTAssertEqual(RepairCopy.receiptHeadline(for: record), "Audio repaired")
    }

    func testFailedReceiptShowsTheError() {
        let record = Fixture.repair(at: Fixture.epoch, succeeded: false, message: "Helper unreachable.")
        XCTAssertEqual(RepairCopy.receiptHeadline(for: record), "Repair failed")
        XCTAssertEqual(RepairCopy.receiptDetail(for: record), "Helper unreachable.")
    }

    func testSummaryLineIsHonestAtZero() {
        XCTAssertEqual(RepairCopy.summaryLine(for: .empty), "No repairs yet. Fennec is listening.")
    }

    func testSummaryLineSingularisesOneRepair() {
        let summary = RepairSummary.make(
            from: [Fixture.repair(at: Fixture.epoch)],
            now: Fixture.epoch.addingTimeInterval(86_400 * 3)
        )
        let line = RepairCopy.summaryLine(for: summary, now: Fixture.epoch.addingTimeInterval(86_400 * 3))
        XCTAssertTrue(line.hasPrefix("1 repair since "), line)
        XCTAssertFalse(line.contains("1 repairs"))
    }

    func testSummaryLineSaysTodayWhenItAllHappenedToday() {
        let now = Fixture.epoch
        let summary = RepairSummary.make(from: [Fixture.repair(at: now), Fixture.repair(at: now)], now: now)
        XCTAssertEqual(RepairCopy.summaryLine(for: summary, now: now), "2 repairs today.")
    }

    func testHeadlineNumberCountsOnlySuccesses() {
        let summary = RepairSummary.make(
            from: [
                Fixture.repair(at: Fixture.epoch),
                Fixture.repair(at: Fixture.epoch, succeeded: false)
            ],
            now: Fixture.epoch
        )
        XCTAssertEqual(RepairCopy.headlineNumber(for: summary), "1")
    }

    /// A person who has just approved the helper must never be told it is
    /// "not enabled"; the blocker names the actual obstacle per state.
    func testHelperBlockerNamesTheActualObstacle() {
        XCTAssertTrue(RepairCopy.helperBlocker(for: .awaitingApproval).contains("Login Items"))
        XCTAssertTrue(RepairCopy.helperBlocker(for: .enabled(reachable: false)).contains("did not answer"))
        XCTAssertEqual(
            RepairCopy.helperBlocker(for: .notConfigured),
            "The automatic repair helper is not enabled."
        )
        XCTAssertEqual(RepairCopy.helperBlocker(for: .unavailable("went sideways")), "went sideways")
        for state: RepairHelperState in [.awaitingApproval, .enabled(reachable: false), .notConfigured] {
            XCTAssertFalse(RepairCopy.helperBlocker(for: state).contains("!"))
        }
    }
}
