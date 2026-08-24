import XCTest

/// The budget exists because the shipping default configuration was a
/// notification cannon: a Mac under load emits overload signals in bursts, and
/// nothing stopped Fennec posting a sound-playing two-button banner for every
/// one it declined to act on.
final class NotificationBudgetTests: XCTestCase {
    private let now = Fixture.epoch

    func testTheFirstNotificationAlwaysGetsThrough() {
        var budget = NotificationBudget(minimumInterval: 600)
        XCTAssertTrue(budget.allow(at: now))
    }

    func testASecondNotificationInsideTheWindowIsHeld() {
        var budget = NotificationBudget(minimumInterval: 600)
        XCTAssertTrue(budget.allow(at: now))
        XCTAssertFalse(budget.allow(at: now.addingTimeInterval(1)))
        XCTAssertFalse(budget.allow(at: now.addingTimeInterval(599)))
    }

    func testTheWindowOpensAgainExactlyOnTime() {
        var budget = NotificationBudget(minimumInterval: 600)
        XCTAssertTrue(budget.allow(at: now))
        XCTAssertTrue(budget.allow(at: now.addingTimeInterval(600)))
    }

    func testABurstIsCountedSoSuppressionIsNeverSilent() {
        var budget = NotificationBudget(minimumInterval: 600)
        XCTAssertTrue(budget.allow(at: now))
        for second in 1...12 {
            _ = budget.allow(at: now.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(budget.suppressedSinceLastPost(), 12)

        XCTAssertTrue(budget.allow(at: now.addingTimeInterval(700)))
        XCTAssertEqual(
            budget.suppressedSinceLastPost(), 12,
            "The count survives until the banner that reports it has been built."
        )
        budget.clearSuppressed()
        XCTAssertNil(budget.suppressedSinceLastPost())
    }

    func testNothingSuppressedReportsNil() {
        var budget = NotificationBudget(minimumInterval: 600)
        XCTAssertTrue(budget.allow(at: now))
        XCTAssertNil(budget.suppressedSinceLastPost())
    }

    func testRemainingCountsDownAndThenClears() {
        var budget = NotificationBudget(minimumInterval: 600)
        XCTAssertNil(budget.remaining(at: now), "Nothing posted yet, so nothing to wait for.")
        _ = budget.allow(at: now)
        XCTAssertEqual(budget.remaining(at: now.addingTimeInterval(100)) ?? 0, 500, accuracy: 0.001)
        XCTAssertNil(budget.remaining(at: now.addingTimeInterval(600)))
    }

    func testASuccessfulRepairResetsTheBudget() {
        var budget = NotificationBudget(minimumInterval: 600)
        _ = budget.allow(at: now)
        _ = budget.allow(at: now.addingTimeInterval(5))

        // The user has just been told a repair happened, so the next thing
        // Fennec declines to act on is news again.
        budget.reset()
        XCTAssertTrue(budget.allow(at: now.addingTimeInterval(6)))
        XCTAssertNil(budget.suppressedSinceLastPost())
    }

    func testAZeroIntervalNeverSuppresses() {
        var budget = NotificationBudget(minimumInterval: 0)
        XCTAssertTrue(budget.allow(at: now))
        XCTAssertTrue(budget.allow(at: now))
    }

    func testNegativeIntervalsAreClampedRatherThanExploding() {
        var budget = NotificationBudget(minimumInterval: -60)
        XCTAssertEqual(budget.minimumInterval, 0)
        XCTAssertTrue(budget.allow(at: now))
        XCTAssertTrue(budget.allow(at: now))
    }

    func testTheDefaultIntervalIsTenMinutes() {
        // A bad afternoon should produce a handful of banners, not a hundred.
        XCTAssertEqual(NotificationBudget.defaultInterval, 600)
        XCTAssertEqual(NotificationBudget().minimumInterval, 600)
    }
}

/// The quiet windows around wake, unlock, and launch. Without them the first
/// thing Fennec does when a laptop lid opens is restart the audio daemon.
final class SystemEventTests: XCTestCase {
    func testEveryEventHasAQuietWindowAndAReason() {
        for event in SystemEvent.allCases {
            XCTAssertGreaterThan(event.quietSeconds, 0, "\(event.rawValue) must suppress something.")
            XCTAssertFalse(event.reason.isEmpty)
            XCTAssertFalse(event.reason.contains("!"))
        }
    }

    func testWakeGetsTheLongestWindow() {
        // Wake renegotiates sample rate, re-enumerates devices, and restarts
        // every audio client at once, often over several seconds.
        let longest = SystemEvent.allCases.max { $0.quietSeconds < $1.quietSeconds }
        XCTAssertEqual(longest, .wake)
    }

    func testEveryWindowOutlastsTheDeviceChangeGrace() {
        // AppModel already gives device and sample-rate changes two seconds.
        // A whole-machine wake must be treated as at least as disruptive.
        for event in SystemEvent.allCases {
            XCTAssertGreaterThanOrEqual(event.quietSeconds, 2)
        }
    }

    func testNoWindowIsSoLongThatFennecStopsBeingUseful() {
        for event in SystemEvent.allCases {
            XCTAssertLessThanOrEqual(
                event.quietSeconds, 30,
                "A quiet window is a blind spot; \(event.rawValue) holds one too long."
            )
        }
    }
}

/// The confirmation card. It replaced two `.alert` modifiers because an alert
/// raised from a `MenuBarExtra(.window)` scene dismisses the popover that is
/// presenting it.
final class PendingConfirmationTests: XCTestCase {
    private let warning = ManualRepairWarning(message: "Microphone input is active in Zoom.")
    private let request = AdministratorRepairRequest(
        reason: "Fennec's repair helper is not enabled, so it cannot restart Core Audio on its own.",
        command: "/usr/bin/killall -TERM coreaudiod"
    )

    func testAudioInUseIsDestructiveAndAdministratorIsNot() {
        XCTAssertTrue(PendingConfirmation.audioInUse(warning).isDestructive)
        XCTAssertFalse(
            PendingConfirmation.administrator(request).isDestructive,
            "Styling a password prompt as destructive trains people to expect red where red does not belong."
        )
    }

    func testOnlyTheAdministratorCardShowsACommand() {
        XCTAssertNil(PendingConfirmation.audioInUse(warning).monospacedDetail)
        XCTAssertEqual(
            PendingConfirmation.administrator(request).monospacedDetail,
            "/usr/bin/killall -TERM coreaudiod"
        )
    }

    func testTheAdministratorCardNamesTheCommandBeforeMacOSAsksForAPassword() {
        let confirmation = PendingConfirmation.administrator(request)
        XCTAssertTrue(confirmation.message.contains("macOS will ask for your password"))
        XCTAssertTrue(confirmation.accessibilityDescription.contains("killall -TERM coreaudiod"))
    }

    func testTheCommandShownIsTheCommandRun() {
        // If these ever drift, the disclosure becomes a lie in the one place
        // that most resembles credential phishing.
        XCTAssertEqual(request.command, PrivilegedPromptRepair.command)
    }

    func testEveryCardHasBothButtonsAndNoneOfThemShout() {
        for confirmation in [PendingConfirmation.audioInUse(warning), .administrator(request)] {
            XCTAssertFalse(confirmation.title.isEmpty)
            XCTAssertFalse(confirmation.message.isEmpty)
            XCTAssertFalse(confirmation.confirmTitle.isEmpty)
            XCTAssertFalse(confirmation.cancelTitle.isEmpty)
            XCTAssertFalse(confirmation.title.contains("!"))
            XCTAssertFalse(confirmation.message.contains("!"))
        }
    }

    func testIdentityFollowsTheUnderlyingRequest() {
        XCTAssertEqual(PendingConfirmation.audioInUse(warning).id, warning.id)
        XCTAssertEqual(PendingConfirmation.administrator(request).id, request.id)
    }
}
