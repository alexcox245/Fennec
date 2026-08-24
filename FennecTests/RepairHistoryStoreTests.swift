import XCTest

@MainActor
final class RepairHistoryStoreTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUp() {
        super.setUp()
        directory = Fixture.temporaryDirectory("repair-history")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAnEmptyStoreReportsNothing() {
        let store = RepairHistoryStore(directory: directory)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.summary, .empty)
        XCTAssertNil(store.lastSuccessfulRepair)
        XCTAssertEqual(RepairCopy.summaryLine(for: store.summary), "No repairs yet. Fennec is listening.")
    }

    func testRecordsAreKeptNewestFirst() {
        let store = RepairHistoryStore(directory: directory)
        store.record(Fixture.repair(at: Fixture.epoch, message: "first"))
        store.record(Fixture.repair(at: Fixture.epoch.addingTimeInterval(60), message: "second"))

        XCTAssertEqual(store.records.map(\.message), ["second", "first"])
        XCTAssertEqual(store.lastSuccessfulRepair?.message, "second")
    }

    func testHistorySurvivesRelaunch() {
        let store = RepairHistoryStore(directory: directory)
        store.record(Fixture.repair(at: Fixture.epoch, message: "before quit"))

        // A menu-bar utility gets quit and relaunched constantly. The count in
        // the popover has to mean something across those restarts.
        let reopened = RepairHistoryStore(directory: directory)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.records.first?.message, "before quit")
        XCTAssertEqual(reopened.summary.successes, 1)
    }

    func testHistoryIsCappedSoItCannotGrowForever() {
        let store = RepairHistoryStore(directory: directory)
        let overflow = RepairHistoryStore.maximumRecords + 25
        for index in 0..<overflow {
            store.record(Fixture.repair(
                at: Fixture.epoch.addingTimeInterval(Double(index)),
                message: "repair \(index)"
            ))
        }

        XCTAssertEqual(store.records.count, RepairHistoryStore.maximumRecords)
        XCTAssertEqual(store.records.first?.message, "repair \(overflow - 1)", "The newest record must survive.")
        XCTAssertEqual(store.records.last?.message, "repair \(overflow - RepairHistoryStore.maximumRecords)")
    }

    func testClearEmptiesTheFileToo() {
        let store = RepairHistoryStore(directory: directory)
        store.record(Fixture.repair(at: Fixture.epoch))
        store.clear()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(RepairHistoryStore(directory: directory).records.isEmpty)
    }

    func testACorruptFileDoesNotTakeTheAppDownWithIt() throws {
        let corrupt = directory.appendingPathComponent(AppConstants.repairHistoryFileName)
        try Data("{ this is not the history you are looking for".utf8).write(to: corrupt)

        let store = RepairHistoryStore(directory: directory)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastError, "The user should be told why their receipts are gone.")
    }

    func testLastSuccessfulRepairSkipsFailures() {
        let store = RepairHistoryStore(directory: directory)
        store.record(Fixture.repair(at: Fixture.epoch, message: "worked"))
        store.record(Fixture.repair(
            at: Fixture.epoch.addingTimeInterval(30),
            succeeded: false,
            message: "helper did not answer"
        ))

        XCTAssertEqual(store.records.first?.succeeded, false)
        XCTAssertEqual(store.lastSuccessfulRepair?.message, "worked")
        XCTAssertEqual(store.summary.successes, 1)
        XCTAssertEqual(store.summary.failures, 1)
    }
}

// MARK: - Summary arithmetic

final class RepairSummaryTests: XCTestCase {
    func testEmptyInputProducesTheEmptySummary() {
        XCTAssertEqual(RepairSummary.make(from: []), .empty)
    }

    func testCountsSplitSuccessesFailuresAndTriggers() {
        let records = [
            Fixture.repair(at: Fixture.epoch, trigger: .automatic),
            Fixture.repair(at: Fixture.epoch, trigger: .manual),
            Fixture.repair(at: Fixture.epoch, trigger: .automatic, succeeded: false)
        ]
        let summary = RepairSummary.make(from: records, now: Fixture.epoch)

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.successes, 2)
        XCTAssertEqual(summary.failures, 1)
        XCTAssertEqual(summary.automatic, 2)
    }

    func testRollingWindowsUseTheSuppliedClock() {
        let now = Fixture.epoch
        let records = [
            Fixture.repair(at: now.addingTimeInterval(-3_600)),          // 1 hour ago
            Fixture.repair(at: now.addingTimeInterval(-3 * 86_400)),     // 3 days ago
            Fixture.repair(at: now.addingTimeInterval(-20 * 86_400)),    // 20 days ago
            Fixture.repair(at: now.addingTimeInterval(-90 * 86_400))     // 90 days ago
        ]
        let summary = RepairSummary.make(from: records, now: now)

        XCTAssertEqual(summary.last24Hours, 1)
        XCTAssertEqual(summary.last7Days, 2)
        XCTAssertEqual(summary.last30Days, 3)
        XCTAssertEqual(summary.total, 4)
    }

    func testDurationStatisticsIgnoreFailuresAndZeroes() {
        let records = [
            Fixture.repair(at: Fixture.epoch, duration: 0.8),
            Fixture.repair(at: Fixture.epoch, duration: 1.4),
            Fixture.repair(at: Fixture.epoch, duration: 2.2),
            Fixture.repair(at: Fixture.epoch, duration: 99, succeeded: false)
        ]
        let summary = RepairSummary.make(from: records, now: Fixture.epoch)

        XCTAssertEqual(summary.fastestSeconds ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(summary.typicalSeconds ?? 0, 1.4, accuracy: 0.0001)
    }

    func testBusiestDeviceCountsOnlySuccessfulRepairs() {
        let records = [
            Fixture.repair(at: Fixture.epoch, device: "MacBook Pro Speakers"),
            Fixture.repair(at: Fixture.epoch, device: "MacBook Pro Speakers"),
            Fixture.repair(at: Fixture.epoch, device: "Studio Display Speakers"),
            Fixture.repair(at: Fixture.epoch, device: "AirPods Max", succeeded: false)
        ]
        XCTAssertEqual(
            RepairSummary.make(from: records, now: Fixture.epoch).busiestDeviceName,
            "MacBook Pro Speakers"
        )
    }

    func testFirstAndLastDatesBoundTheWholeRun() {
        let records = [
            Fixture.repair(at: Fixture.epoch.addingTimeInterval(500)),
            Fixture.repair(at: Fixture.epoch),
            Fixture.repair(at: Fixture.epoch.addingTimeInterval(250))
        ]
        let summary = RepairSummary.make(from: records, now: Fixture.epoch.addingTimeInterval(600))
        XCTAssertEqual(summary.firstDate, Fixture.epoch)
        XCTAssertEqual(summary.lastDate, Fixture.epoch.addingTimeInterval(500))
    }
}
