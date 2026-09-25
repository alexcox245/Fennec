import XCTest

/// `DetectionEngine` is the whole product decision in 80 lines: how many
/// Core Audio failure signals, inside what window, count as "the crackle
/// started". These tests pin the thresholds the UI promises the user.
final class DetectionEngineTests: XCTestCase {
    private var engine = DetectionEngine()

    override func setUp() {
        super.setUp()
        engine = DetectionEngine()
    }

    func testBalancedDescriptionUsesApprovedMenuCopy() {
        XCTAssertEqual(
            DetectionSensitivity.balanced.detail,
            "Waits for 2 signals within 3 seconds. You hear the crackle begin. Then silence. Then your sweet sweet beats."
        )
    }

    // MARK: Balanced: "let it crackle twice, then fix it"

    func testBalancedIgnoresASingleOverload() {
        let decision = engine.ingest(
            Fixture.batch(at: Fixture.epoch, overloads: 1),
            sensitivity: .balanced
        )
        XCTAssertNil(decision, "One overload is a blip, not the failure. Fennec must not repair on it.")
    }

    func testBalancedFiresOnTheSecondOverloadInsideTheWindow() {
        XCTAssertNil(engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 1), sensitivity: .balanced))

        let decision = engine.ingest(
            Fixture.batch(at: Fixture.epoch.addingTimeInterval(2), overloads: 1),
            sensitivity: .balanced
        )

        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.signal, .processorOverload)
        XCTAssertEqual(decision?.signalCount, 2)
        XCTAssertEqual(decision?.reason, "Core Audio missed its real-time output deadline 2 times within 3 seconds.")
    }

    func testBalancedDoesNotFireWhenTheSecondOverloadFallsOutsideTheWindow() {
        XCTAssertNil(engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 1), sensitivity: .balanced))

        let decision = engine.ingest(
            Fixture.batch(at: Fixture.epoch.addingTimeInterval(4), overloads: 1),
            sensitivity: .balanced
        )

        XCTAssertNil(decision, "Two overloads four seconds apart are not the same failure.")
    }

    func testTwoOverloadsInOneDrainBatchStillCount() {
        // The 250 ms drain can carry both signals of a fast double-fault.
        let decision = engine.ingest(
            Fixture.batch(at: Fixture.epoch, overloads: 2),
            sensitivity: .balanced
        )
        XCTAssertEqual(decision?.signalCount, 2)
    }

    func testFiringClearsTheWindowSoTheNextRepairNeedsTwoFreshSignals() {
        _ = engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 2), sensitivity: .balanced)

        let next = engine.ingest(
            Fixture.batch(at: Fixture.epoch.addingTimeInterval(1), overloads: 1),
            sensitivity: .balanced
        )
        XCTAssertNil(next, "After a decision the counter restarts; one leftover signal must not re-fire.")
    }

    func testDecisionReportsTheRealElapsedSpanNotTheConfiguredWindow() {
        _ = engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 1), sensitivity: .balanced)
        let decision = engine.ingest(
            Fixture.batch(at: Fixture.epoch.addingTimeInterval(2.2), overloads: 1),
            sensitivity: .balanced
        )

        // "2 signals in 2.2 s" is a fact about the user's machine.
        // "within 3 seconds" is only a fact about their settings.
        XCTAssertEqual(decision?.elapsedSeconds ?? 0, 2.2, accuracy: 0.001)
        XCTAssertEqual(decision?.windowSeconds, 3)
    }

    func testSignalsFromOneDrainReportZeroElapsed() {
        let decision = engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 2), sensitivity: .balanced)
        XCTAssertEqual(decision?.elapsedSeconds, 0)
    }

    func testAbnormalStopReportsNoSpan() {
        let decision = engine.ingest(Fixture.batch(at: Fixture.epoch, abnormalStops: 1), sensitivity: .balanced)
        XCTAssertEqual(decision?.elapsedSeconds, 0)
        XCTAssertEqual(decision?.windowSeconds, 3)
    }

    // MARK: Conservative and Immediate

    func testConservativeNeedsThreeOverloads() {
        XCTAssertNil(engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 1), sensitivity: .conservative))
        XCTAssertNil(engine.ingest(Fixture.batch(at: Fixture.epoch.addingTimeInterval(3), overloads: 1), sensitivity: .conservative))

        let decision = engine.ingest(
            Fixture.batch(at: Fixture.epoch.addingTimeInterval(6), overloads: 1),
            sensitivity: .conservative
        )
        XCTAssertEqual(decision?.signalCount, 3)
        XCTAssertEqual(decision?.reason, "Core Audio missed its real-time output deadline 3 times within 12 seconds.")
    }

    func testImmediateFiresOnTheFirstOverload() {
        let decision = engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 1), sensitivity: .immediate)
        XCTAssertEqual(decision?.signalCount, 1)
        XCTAssertEqual(decision?.reason, "Core Audio missed its real-time output deadline 1 time within 2 seconds.")
    }

    // MARK: Abnormal I/O stop

    func testAbnormalStopAlwaysFiresImmediately() {
        for sensitivity in DetectionSensitivity.allCases {
            let engine = DetectionEngine()
            let decision = engine.ingest(
                Fixture.batch(at: Fixture.epoch, abnormalStops: 1),
                sensitivity: sensitivity
            )
            XCTAssertEqual(
                decision?.signal, .ioStoppedAbnormally,
                "An abnormal I/O stop is unambiguous; \(sensitivity.title) must still act on it."
            )
        }
    }

    func testAbnormalStopClearsPendingOverloads() {
        _ = engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 1), sensitivity: .balanced)
        _ = engine.ingest(Fixture.batch(at: Fixture.epoch.addingTimeInterval(1), abnormalStops: 1), sensitivity: .balanced)

        let next = engine.ingest(
            Fixture.batch(at: Fixture.epoch.addingTimeInterval(2), overloads: 1),
            sensitivity: .balanced
        )
        XCTAssertNil(next, "The stale overload must not combine with a post-repair signal.")
    }

    // MARK: Housekeeping

    func testBatchWithNoFailureSignalProducesNoDecision() {
        XCTAssertNil(engine.ingest(
            Fixture.batch(at: Fixture.epoch, defaultOutputChanges: 1, sampleRateChanges: 1),
            sensitivity: .immediate
        ))
    }

    func testResetDiscardsThePartialWindow() {
        _ = engine.ingest(Fixture.batch(at: Fixture.epoch, overloads: 1), sensitivity: .balanced)
        engine.reset()

        XCTAssertNil(
            engine.ingest(Fixture.batch(at: Fixture.epoch.addingTimeInterval(1), overloads: 1), sensitivity: .balanced),
            "reset() is called around device switches and repairs; it must drop history."
        )
    }

    func testSensitivityCopyMatchesItsThresholds() {
        // The Settings screen shows `detail`; if it drifts from the numbers the
        // engine actually uses, the product lies to the user.
        XCTAssertEqual(DetectionSensitivity.conservative.threshold, 3)
        XCTAssertEqual(DetectionSensitivity.conservative.window, 12)
        XCTAssertEqual(DetectionSensitivity.balanced.threshold, 2)
        XCTAssertEqual(DetectionSensitivity.balanced.window, 3)
        XCTAssertEqual(DetectionSensitivity.immediate.threshold, 1)

        for sensitivity in DetectionSensitivity.allCases {
            XCTAssertTrue(
                sensitivity.detail.contains("\(sensitivity.threshold)")
                    || sensitivity == .immediate,
                "\(sensitivity.title) copy should name its threshold."
            )
        }
    }

    func testContainsFailureSignalOnlyCountsOverloadsAndStops() {
        XCTAssertFalse(Fixture.batch(at: Fixture.epoch, defaultOutputChanges: 3).containsFailureSignal)
        XCTAssertTrue(Fixture.batch(at: Fixture.epoch, overloads: 1).containsFailureSignal)
        XCTAssertTrue(Fixture.batch(at: Fixture.epoch, abnormalStops: 1).containsFailureSignal)
    }
}
