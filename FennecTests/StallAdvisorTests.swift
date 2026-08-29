import XCTest

final class StallAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func stops(_ offsets: [TimeInterval]) -> [Date] {
        offsets.map { now.addingTimeInterval(-$0) }
    }

    // MARK: The pattern gate

    func testTwoStopsAreAPauseAndAPlay() {
        XCTAssertNil(StallAdvisor.assess(
            stopDates: stops([10, 60]),
            now: now,
            loadPerCore: 3.0,
            memoryPressureLevel: 4
        ))
    }

    func testThreeStopsOnABusyMachineAdvise() {
        let advisory = StallAdvisor.assess(
            stopDates: stops([10, 60, 120]),
            now: now,
            loadPerCore: 1.5,
            memoryPressureLevel: 1
        )
        XCTAssertEqual(advisory?.stopCount, 3)
    }

    func testStopsOlderThanTheWindowDoNotCount() {
        XCTAssertNil(StallAdvisor.assess(
            stopDates: stops([10, 60, StallAdvisor.window + 1]),
            now: now,
            loadPerCore: 3.0,
            memoryPressureLevel: 4
        ))
    }

    // MARK: The starvation gate

    func testAnIdleMachineGetsNoAdvisoryHoweverChurnyPlaybackIs() {
        // Someone skipping through an album is not a system problem.
        XCTAssertNil(StallAdvisor.assess(
            stopDates: stops([5, 15, 25, 35, 45]),
            now: now,
            loadPerCore: 0.3,
            memoryPressureLevel: 1
        ))
    }

    func testMemoryPressureAloneIsEnough() {
        let advisory = StallAdvisor.assess(
            stopDates: stops([10, 60, 120]),
            now: now,
            loadPerCore: 0.3,
            memoryPressureLevel: StallAdvisor.memoryPressureFloor
        )
        XCTAssertNotNil(advisory)
        XCTAssertEqual(advisory?.memoryPressureLabel, "warning")
    }

    func testCriticalPressureIsNamedCritical() {
        let advisory = StallAdvisory(
            stopCount: 3,
            windowSeconds: StallAdvisor.window,
            loadPerCore: 0.5,
            memoryPressureLevel: 4
        )
        XCTAssertEqual(advisory.memoryPressureLabel, "critical")
    }

    // MARK: The copy

    func testAdvisoryCopySaysTheNumbersAndRefusesTheWrongCure() {
        let advisory = StallAdvisory(
            stopCount: 4,
            windowSeconds: 180,
            loadPerCore: 1.47,
            memoryPressureLevel: 2
        )
        let body = RepairCopy.stallAdvisoryBody(for: advisory)
        XCTAssertTrue(body.contains("4 times in 3 minutes"))
        // The load average and the memory-pressure level moved to the event
        // log (T-043). The banner says the consequence, not the metric.
        XCTAssertFalse(body.lowercased().contains("per core"), body)
        XCTAssertFalse(body.lowercased().contains("memory pressure"), body)
        XCTAssertFalse(body.lowercased().contains("core audio"), body)
        XCTAssertTrue(body.contains("working too hard"), body)
        XCTAssertTrue(body.contains("repairing will not help"), body)
    }

    func testAdvisoryCopyOmitsNormalMemoryPressure() {
        let advisory = StallAdvisory(
            stopCount: 3,
            windowSeconds: 180,
            loadPerCore: 2.0,
            memoryPressureLevel: 1
        )
        let body = RepairCopy.stallAdvisoryBody(for: advisory)
        XCTAssertFalse(body.contains("memory pressure"))
    }

    func testAdvisoryCopyDoesNotShoutOrEmote() {
        let advisory = StallAdvisory(
            stopCount: 3,
            windowSeconds: 180,
            loadPerCore: 1.3,
            memoryPressureLevel: 2
        )
        for text in [RepairCopy.stallAdvisoryTitle(), RepairCopy.stallAdvisoryBody(for: advisory)] {
            XCTAssertFalse(text.contains("!"))
            XCTAssertNil(text.unicodeScalars.first { $0.properties.isEmojiPresentation })
        }
    }
}
