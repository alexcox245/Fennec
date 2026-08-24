import XCTest

/// Pause exists because Fennec's safety checks can only see what Core Audio
/// tells them, and a person about to hit record knows more than that. The
/// thing it must never do is outlive its own expiry — a pause silently left
/// on is indistinguishable from a broken app.
final class PauseScheduleTests: XCTestCase {
    private let now = Fixture.epoch

    // MARK: Durations

    func testEveryOptionHasATitleAndOnlyOneIsIndefinite() {
        let indefinite = PauseSchedule.Option.allCases.filter { $0.duration == nil }
        XCTAssertEqual(indefinite, [.untilResumed])
        for option in PauseSchedule.Option.allCases {
            XCTAssertFalse(option.title.isEmpty)
            XCTAssertFalse(option.title.contains("!"))
        }
    }

    func testDurationsAreWhatTheirNamesSay() {
        XCTAssertEqual(PauseSchedule.Option.fifteenMinutes.duration, 15 * 60)
        XCTAssertEqual(PauseSchedule.Option.oneHour.duration, 3_600)
        XCTAssertEqual(PauseSchedule.Option.fourHours.duration, 4 * 3_600)
    }

    func testExpiryIsMeasuredFromTheGivenInstant() {
        XCTAssertEqual(
            PauseSchedule.expiry(for: .oneHour, from: now),
            now.addingTimeInterval(3_600)
        )
        XCTAssertNil(PauseSchedule.expiry(for: .untilResumed, from: now))
    }

    // MARK: State

    func testRunningIsNotPaused() {
        XCTAssertFalse(PauseState.running.isPaused(at: now))
        XCTAssertNil(PauseState.running.statusText(at: now))
        XCTAssertNil(PauseState.running.remaining(at: now))
    }

    func testATimedPauseEndsOnItsOwn() {
        let state = PauseState.make(for: .fifteenMinutes, from: now)
        XCTAssertTrue(state.isPaused(at: now))
        XCTAssertTrue(state.isPaused(at: now.addingTimeInterval(14 * 60)))
        XCTAssertFalse(
            state.isPaused(at: now.addingTimeInterval(15 * 60)),
            "The whole point of a timed pause is that it stops being one."
        )
    }

    func testAnIndefinitePauseNeverExpires() {
        let state = PauseState.make(for: .untilResumed, from: now)
        XCTAssertTrue(state.isPaused(at: now.addingTimeInterval(365 * 86_400)))
        XCTAssertNil(state.remaining(at: now))
        XCTAssertEqual(state.statusText(at: now), "Paused")
    }

    func testAStaleTimestampResolvesToRunning() {
        // This is what survives a reboot: a pausedUntil that expired while
        // Fennec was not running must not come back as a pause.
        let expired = PauseState.until(now.addingTimeInterval(-60))
        XCTAssertFalse(expired.isPaused(at: now))
        XCTAssertEqual(expired.resolved(at: now), .running)
    }

    func testResolvedKeepsALivePause() {
        let live = PauseState.make(for: .fourHours, from: now)
        XCTAssertEqual(live.resolved(at: now.addingTimeInterval(60)), live)
    }

    func testRemainingCountsDown() {
        let state = PauseState.make(for: .oneHour, from: now)
        XCTAssertEqual(state.remaining(at: now) ?? 0, 3_600, accuracy: 0.001)
        XCTAssertEqual(state.remaining(at: now.addingTimeInterval(3_000)) ?? 0, 600, accuracy: 0.001)
        XCTAssertNil(state.remaining(at: now.addingTimeInterval(3_600)))
    }

    // MARK: Status text

    func testStatusTextStatesTheDeadlineRatherThanTicking() {
        let state = PauseState.make(for: .oneHour, from: now)
        XCTAssertEqual(state.statusText(at: now.addingTimeInterval(18 * 60)), "Paused · resumes in 42 min")
    }

    func testHoursAreRenderedAsHours() {
        let state = PauseState.make(for: .fourHours, from: now)
        XCTAssertEqual(state.statusText(at: now), "Paused · resumes in 4 h")
        XCTAssertEqual(state.statusText(at: now.addingTimeInterval(3_600)), "Paused · resumes in 3 h")
    }

    func testAHalfHourIsNotRoundedAwayToNothing() {
        let state = PauseState.until(now.addingTimeInterval(90 * 60))
        XCTAssertEqual(state.statusText(at: now), "Paused · resumes in 1.5 h")
    }

    func testTheLastMinuteDoesNotCountSeconds() {
        let state = PauseState.until(now.addingTimeInterval(20))
        XCTAssertEqual(state.statusText(at: now), "Paused · resumes in under a minute")
    }

    func testStatusTextIsNilOnceItHasExpired() {
        let state = PauseState.make(for: .fifteenMinutes, from: now)
        XCTAssertNil(state.statusText(at: now.addingTimeInterval(20 * 60)))
    }

    // MARK: Persistence shape

    @MainActor
    func testPauseRoundTripsThroughUserDefaults() {
        let suite = "FennecTests-pause-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.pauseState, .running)

        store.pauseState = .make(for: .oneHour, from: now)
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.pauseState.until, now.addingTimeInterval(3_600))
        XCTAssertFalse(reopened.pauseState.isIndefinite)
    }

    @MainActor
    func testAnIndefinitePauseAlsoSurvivesRelaunch() {
        let suite = "FennecTests-pause-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        SettingsStore(defaults: defaults).pauseState = .indefinite()
        XCTAssertTrue(SettingsStore(defaults: defaults).pauseState.isPaused(at: now))
    }
}
