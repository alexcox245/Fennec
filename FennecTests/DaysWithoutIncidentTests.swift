import XCTest

/// The sign on the workshop wall. It counts up while nothing goes wrong and
/// reads 0 on the day something does, with no softening — which only works if
/// the arithmetic is calendar days and not elapsed hours.
final class DaysWithoutIncidentTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter.date(from: iso)!
    }

    private func make(
        repairsAt dates: [String],
        listeningSince: String,
        now: String
    ) -> DaysWithoutIncident {
        DaysWithoutIncident.make(
            records: dates.map { Fixture.repair(at: date($0)) },
            listeningSince: date(listeningSince),
            now: date(now),
            calendar: calendar
        )
    }

    // MARK: A clean record

    func testFirstDayReadsZeroAndSaysWhy() {
        let sign = make(repairsAt: [], listeningSince: "2027-03-01T09:00:00Z", now: "2027-03-01T22:00:00Z")
        XCTAssertEqual(sign.days, 0)
        XCTAssertTrue(sign.isCleanRecord)
        XCTAssertEqual(sign.caption, "Fennec started listening today.")
    }

    func testAWeekWithNoRepairsCountsSevenDays() {
        let sign = make(repairsAt: [], listeningSince: "2027-03-01T09:00:00Z", now: "2027-03-08T00:30:00Z")
        XCTAssertEqual(sign.days, 7)
        XCTAssertEqual(sign.caption, "Fennec has never had to step in.")
    }

    func testTheCountRollsOverAtMidnightNotAfterTwentyFourHours() {
        // 23:59 on day one is still zero; 00:01 on day two is one.
        XCTAssertEqual(make(repairsAt: [], listeningSince: "2027-03-01T09:00:00Z", now: "2027-03-01T23:59:00Z").days, 0)
        XCTAssertEqual(make(repairsAt: [], listeningSince: "2027-03-01T09:00:00Z", now: "2027-03-02T00:01:00Z").days, 1)
    }

    // MARK: After an incident

    func testARepairTodayResetsTheSignToZero() {
        let sign = make(
            repairsAt: ["2027-03-10T14:00:00Z"],
            listeningSince: "2027-01-01T00:00:00Z",
            now: "2027-03-10T23:00:00Z"
        )
        XCTAssertEqual(sign.days, 0)
        XCTAssertFalse(sign.isCleanRecord)
        XCTAssertEqual(sign.caption, "Last repair today.", "No softening on the day it happened.")
    }

    func testItCountsFromTheMostRecentRepair() {
        let sign = make(
            repairsAt: ["2027-03-01T10:00:00Z", "2027-03-10T14:00:00Z", "2027-02-02T10:00:00Z"],
            listeningSince: "2027-01-01T00:00:00Z",
            now: "2027-03-24T08:00:00Z"
        )
        XCTAssertEqual(sign.days, 14)
        XCTAssertEqual(sign.lastIncident, date("2027-03-10T14:00:00Z"))
    }

    func testTheCaptionNamesTheDayOfTheLastRepair() {
        let sign = make(
            repairsAt: ["2027-03-10T14:00:00Z"],
            listeningSince: "2027-01-01T00:00:00Z",
            now: "2027-03-24T08:00:00Z"
        )
        XCTAssertTrue(sign.caption.hasPrefix("Last repair "), sign.caption)
        XCTAssertFalse(sign.caption.contains("!"))
    }

    func testAFailedRepairIsStillAnIncident() {
        // Fennec had to step in; whether it worked is a different question and
        // a different part of the UI.
        let sign = DaysWithoutIncident.make(
            records: [Fixture.repair(at: date("2027-03-10T14:00:00Z"), succeeded: false, outcome: .failed)],
            listeningSince: date("2027-01-01T00:00:00Z"),
            now: date("2027-03-11T08:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(sign.days, 1)
        XCTAssertFalse(sign.isCleanRecord)
    }

    func testAManualRepairCountsToo() {
        let sign = DaysWithoutIncident.make(
            records: [Fixture.repair(at: date("2027-03-10T14:00:00Z"), trigger: .manual)],
            listeningSince: date("2027-01-01T00:00:00Z"),
            now: date("2027-03-12T08:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(sign.days, 2, "The user only pressed the button because something was wrong.")
    }

    // MARK: Not lying

    func testTheSignNeverGoesNegative() {
        // A clock change, a restored backup, or a record from the future must
        // not produce "-3 days without incident".
        let sign = make(
            repairsAt: ["2027-06-01T10:00:00Z"],
            listeningSince: "2027-01-01T00:00:00Z",
            now: "2027-03-01T10:00:00Z"
        )
        XCTAssertEqual(sign.days, 0)
    }

    func testAFutureListeningDateAlsoClampsToZero() {
        let sign = make(repairsAt: [], listeningSince: "2028-01-01T00:00:00Z", now: "2027-03-01T10:00:00Z")
        XCTAssertEqual(sign.days, 0)
    }

    func testTheAccessibilityLabelIsASentenceNotANumeral() {
        let one = make(repairsAt: [], listeningSince: "2027-03-01T09:00:00Z", now: "2027-03-02T09:00:00Z")
        XCTAssertEqual(one.accessibilityLabel, "1 day without incident. Fennec has never had to step in.")

        let many = make(repairsAt: [], listeningSince: "2027-03-01T09:00:00Z", now: "2027-03-06T09:00:00Z")
        XCTAssertTrue(many.accessibilityLabel.hasPrefix("5 days without incident."))
    }

    @MainActor
    func testListeningSinceIsStampedOnceAndNeverMoves() {
        let suite = "FennecTests-since-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults).listeningSince
        XCTAssertEqual(
            SettingsStore(defaults: defaults).listeningSince, first,
            "If this moved on every launch the sign would read 0 forever."
        )
    }
}
