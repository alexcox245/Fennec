import XCTest

/// "Menu-bar utility wakes four times a second, forever" is a top comment in
/// any Mac forum thread, and it was true: the drain timer ran at 250 ms
/// whether or not a signal had ever arrived.
final class DrainScheduleTests: XCTestCase {

    func testItStartsFastAndStaysFastWhileSignalsArrive() {
        XCTAssertEqual(DrainSchedule.interval(quietFor: 0), DrainSchedule.active)
        XCTAssertEqual(DrainSchedule.interval(quietFor: 59), DrainSchedule.active)
    }

    func testItBacksOffAfterAQuietMinute() {
        XCTAssertEqual(DrainSchedule.interval(quietFor: 60), DrainSchedule.idle)
        XCTAssertEqual(DrainSchedule.interval(quietFor: 299), DrainSchedule.idle)
    }

    func testItBacksOffFurtherAfterFiveQuietMinutes() {
        XCTAssertEqual(DrainSchedule.interval(quietFor: 300), DrainSchedule.deepIdle)
        XCTAssertEqual(DrainSchedule.interval(quietFor: 86_400), DrainSchedule.deepIdle)
    }

    func testTheTiersOnlyEverGetSlower() {
        var previous = DrainSchedule.interval(quietFor: 0)
        for quiet in stride(from: 0.0, through: 600.0, by: 5) {
            let interval = DrainSchedule.interval(quietFor: quiet)
            XCTAssertGreaterThanOrEqual(interval, previous, "The schedule must be monotonic at \(quiet) s.")
            previous = interval
        }
    }

    func testTheIdleTiersCutWakeUpsByAtLeastThreeQuarters() {
        // The whole point. At 250 ms that is 4 wake-ups a second forever.
        XCTAssertLessThanOrEqual(DrainSchedule.active / DrainSchedule.idle, 0.25)
        XCTAssertLessThanOrEqual(DrainSchedule.active / DrainSchedule.deepIdle, 0.125)
    }

    func testLeewayIsTightWhileActiveAndGenerousWhileIdle() {
        // Tight when the timing is load-bearing; generous when it is not, so
        // the kernel can coalesce Fennec's wake-ups with everything else.
        XCTAssertLessThanOrEqual(DrainSchedule.leeway(for: DrainSchedule.active), 0.05)
        XCTAssertGreaterThanOrEqual(DrainSchedule.leeway(for: DrainSchedule.deepIdle), 0.5)
    }

    func testTheSlowestTierStillOutpacesTheTightestDetectionWindow() {
        // Immediate mode uses a 2 s window. A drain slower than that could
        // let both halves of a detection land in one batch and go unnoticed.
        XCTAssertLessThanOrEqual(
            DrainSchedule.deepIdle, DetectionSensitivity.immediate.window,
            "Backing off must delay noticing a signal, never lose one."
        )
    }

    func testTheSlowestTierIsSmallComparedToTheBalancedWindow() {
        XCTAssertLessThan(DrainSchedule.deepIdle, DetectionSensitivity.balanced.window / 3)
    }
}
