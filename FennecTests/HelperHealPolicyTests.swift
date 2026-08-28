import XCTest

/// The self-heal must fire exactly when a registration is broken and the user
/// has already said yes, and never anywhere else. Getting the guard wrong in
/// one direction re-registers a daemon the user disabled on purpose; in the
/// other, it leaves "Enabled, not responding" as a password prompt at 2am.
final class HelperHealPolicyTests: XCTestCase {

    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testItHealsAnEnabledHelperThatIsNotAnswering() {
        var policy = HelperHealPolicy()
        XCTAssertTrue(policy.shouldAttempt(enabled: true, reachable: false, userInitiated: false, now: epoch))
    }

    func testItNeverTouchesAHelperThatIsAnswering() {
        var policy = HelperHealPolicy()
        XCTAssertFalse(policy.shouldAttempt(enabled: true, reachable: true, userInitiated: false, now: epoch))
        XCTAssertFalse(policy.shouldAttempt(enabled: true, reachable: true, userInitiated: true, now: epoch))
    }

    func testItNeverTouchesARegistrationTheUserHasNotEnabled() {
        // `.requiresApproval` and `.notRegistered` both report enabled: false.
        // Healing there would convert the user's decision into Fennec's.
        var policy = HelperHealPolicy()
        XCTAssertFalse(policy.shouldAttempt(enabled: false, reachable: false, userInitiated: false, now: epoch))
        XCTAssertFalse(policy.shouldAttempt(enabled: false, reachable: false, userInitiated: true, now: epoch))
    }

    func testAutomaticAttemptsAreRateLimited() {
        var policy = HelperHealPolicy()
        XCTAssertTrue(policy.shouldAttempt(enabled: true, reachable: false, userInitiated: false, now: epoch))
        XCTAssertFalse(policy.shouldAttempt(
            enabled: true, reachable: false, userInitiated: false,
            now: epoch.addingTimeInterval(HelperHealPolicy.defaultInterval - 1)
        ))
        XCTAssertTrue(policy.shouldAttempt(
            enabled: true, reachable: false, userInitiated: false,
            now: epoch.addingTimeInterval(HelperHealPolicy.defaultInterval)
        ))
    }

    func testAUserInitiatedAttemptIgnoresTheRateLimit() {
        // The interval stops Fennec from flapping the registration; it must
        // not make the Settings button do nothing.
        var policy = HelperHealPolicy()
        XCTAssertTrue(policy.shouldAttempt(enabled: true, reachable: false, userInitiated: false, now: epoch))
        XCTAssertTrue(policy.shouldAttempt(enabled: true, reachable: false, userInitiated: true, now: epoch.addingTimeInterval(1)))
    }

    func testAUserInitiatedAttemptStillResetsTheAutomaticClock() {
        var policy = HelperHealPolicy()
        XCTAssertTrue(policy.shouldAttempt(enabled: true, reachable: false, userInitiated: true, now: epoch))
        XCTAssertFalse(policy.shouldAttempt(
            enabled: true, reachable: false, userInitiated: false,
            now: epoch.addingTimeInterval(1)
        ))
    }

    func testARefusedAttemptDoesNotResetTheClock() {
        var policy = HelperHealPolicy()
        XCTAssertTrue(policy.shouldAttempt(enabled: true, reachable: false, userInitiated: false, now: epoch))
        // A reachable probe mid-interval must not push the next attempt out.
        XCTAssertFalse(policy.shouldAttempt(
            enabled: true, reachable: true, userInitiated: false,
            now: epoch.addingTimeInterval(HelperHealPolicy.defaultInterval - 1)
        ))
        XCTAssertTrue(policy.shouldAttempt(
            enabled: true, reachable: false, userInitiated: false,
            now: epoch.addingTimeInterval(HelperHealPolicy.defaultInterval)
        ))
    }
}
