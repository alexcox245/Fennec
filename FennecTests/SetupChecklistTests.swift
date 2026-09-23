import XCTest

/// The checklist decides what the popover and the first-run window ask the
/// user to do. Getting it wrong means either nagging someone who is already
/// set up, or quietly leaving Fennec unable to do its job.
final class SetupChecklistTests: XCTestCase {

    private func remaining(
        helper: RepairHelperState = .notConfigured,
        loginItem: LoginItemState = .notRegistered,
        notifications: Bool = false,
        repairMode: RepairMode = .automatic,
        location: InstallLocation = .applications
    ) -> [SetupStep] {
        SetupChecklist.remaining(
            helper: helper,
            loginItem: loginItem,
            notificationsAuthorized: notifications,
            repairMode: repairMode,
            location: location
        )
    }

    func testAutomaticModeOnlyBlocksOnTheHelper() {
        let steps = remaining()
        XCTAssertEqual(steps.map(\.kind), [.helper])
        XCTAssertTrue(steps.allSatisfy(\.isRequired))
    }

    func testAskFirstNeedsNoBackgroundPermissions() {
        XCTAssertTrue(remaining(repairMode: .askFirst).isEmpty)
        XCTAssertTrue(SetupChecklist.isReady(helper: .notConfigured, loginItem: .notRegistered, repairMode: .askFirst))
        XCTAssertEqual(
            SetupChecklist.summary(
                helper: .notConfigured,
                loginItem: .notRegistered,
                notificationsAuthorized: false,
                repairMode: .askFirst
            ),
            "Ask me first is ready."
        )
    }

    func testAFullyConfiguredMacHasNothingLeft() {
        XCTAssertTrue(remaining(helper: .enabled(reachable: true), loginItem: .enabled, notifications: true).isEmpty)
    }

    func testTheChecklistAlwaysReportsAllFourStepsRegardlessOfState() {
        let steps = SetupChecklist.steps(
            helper: .enabled(reachable: true),
            loginItem: .enabled,
            notificationsAuthorized: true,
            location: .applications
        )
        XCTAssertEqual(steps.count, 4)
        XCTAssertTrue(steps.allSatisfy(\.isComplete))
    }

    // MARK: Install location

    func testApplicationsCountsAsInstalled() {
        XCTAssertTrue(remaining(location: .applications).allSatisfy { $0.kind != .install })
    }

    func testRunningFromElsewhereIsARequiredStepAndItLeads() throws {
        let steps = remaining(location: .elsewhere("~/Downloads"))
        let install = try XCTUnwrap(steps.first { $0.kind == .install })
        XCTAssertTrue(install.isRequired)
        XCTAssertEqual(install.actionTitle, "Move to Applications")
        XCTAssertTrue(install.detail.contains("~/Downloads"))
        // Registrations bind to the bundle path, so nothing else on the list
        // is safe to do first.
        XCTAssertEqual(steps.first?.kind, .install)
    }

    func testADevelopmentBuildIsNotRequired() throws {
        let steps = SetupChecklist.steps(
            helper: .enabled(reachable: true),
            loginItem: .notRegistered,
            notificationsAuthorized: false,
            location: .developmentBuild
        )
        let install = try XCTUnwrap(steps.first { $0.kind == .install })
        XCTAssertFalse(install.isRequired)
    }

    // MARK: Helper states

    func testAnInstalledButUnresponsiveHelperIsNotComplete() throws {
        let steps = remaining(helper: .enabled(reachable: false))
        let helperStep = try XCTUnwrap(steps.first { $0.kind == .helper })
        // The action rebuilds the registration (the fix) rather than
        // re-pinging a daemon that cannot answer and calling it a day.
        XCTAssertEqual(helperStep.actionTitle, "Reconnect")
        XCTAssertFalse(helperStep.isComplete)
    }

    func testAStagedHelperAsksForApprovalRatherThanInstallingAgain() {
        let steps = remaining(helper: .awaitingApproval)
        XCTAssertTrue(steps.contains { $0.kind == .helperApproval })
        XCTAssertFalse(
            steps.contains { $0.kind == .helper },
            "Offering Enable again when macOS already staged it sends the user in a circle."
        )
    }

    func testAnUnavailableHelperShowsTheRealReason() throws {
        let steps = remaining(helper: .unavailable("Fennec is not in the Applications folder."))
        let step = try XCTUnwrap(steps.first { $0.kind == .helper })
        XCTAssertEqual(step.detail, "Fennec is not in the Applications folder.")
        XCTAssertEqual(step.actionTitle, "Try Again")
    }

    // MARK: Login item states

    func testAStagedLoginItemSendsTheUserToSystemSettings() throws {
        let steps = SetupChecklist.steps(
            helper: .enabled(reachable: true),
            loginItem: .requiresApproval,
            notificationsAuthorized: false
        )
        let step = try XCTUnwrap(steps.first { $0.kind == .loginItem })
        XCTAssertEqual(step.actionTitle, "Open Login Items…")
        XCTAssertFalse(step.isRequired)
    }

    func testAnUnregisteredLoginItemOffersToTurnItOn() throws {
        let steps = SetupChecklist.steps(
            helper: .enabled(reachable: true),
            loginItem: .notRegistered,
            notificationsAuthorized: false
        )
        let step = try XCTUnwrap(steps.first { $0.kind == .loginItem })
        XCTAssertEqual(step.actionTitle, "Turn On")
        XCTAssertFalse(step.isRequired, "Starting at login is optional.")
    }

    func testLoginItemStateMapsEverySMAppServiceStatus() {
        XCTAssertEqual(LoginItemState.from(.enabled), .enabled)
        XCTAssertEqual(LoginItemState.from(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemState.from(.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemState.from(.notFound), .notFound)

        XCTAssertTrue(LoginItemState.enabled.isEnabled)
        XCTAssertFalse(LoginItemState.notFound.isEnabled)
        XCTAssertTrue(LoginItemState.requiresApproval.requiresApproval)
    }

    func testEveryLoginItemStateHasAUsefulSentence() {
        let states: [LoginItemState] = [.enabled, .requiresApproval, .notRegistered, .notFound, .unknown("odd")]
        for state in states {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
        }
    }

    // MARK: Readiness and the summary line

    func testAutomaticReadinessNeedsTheHelperButNotTheLoginItem() {
        XCTAssertTrue(SetupChecklist.isReady(helper: .enabled(reachable: true), loginItem: .enabled))
        XCTAssertTrue(SetupChecklist.isReady(helper: .enabled(reachable: true), loginItem: .notRegistered))
        XCTAssertFalse(SetupChecklist.isReady(helper: .enabled(reachable: false), loginItem: .enabled))
        XCTAssertFalse(SetupChecklist.isReady(helper: .notConfigured, loginItem: .enabled))
    }

    func testSummaryCountsOnlyBlockingWork() {
        XCTAssertEqual(
            SetupChecklist.summary(helper: .notConfigured, loginItem: .notRegistered, notificationsAuthorized: false),
            "1 step before automatic repair is ready."
        )
        XCTAssertEqual(
            SetupChecklist.summary(helper: .enabled(reachable: true), loginItem: .enabled, notificationsAuthorized: false),
            "Automatic repair is ready."
        )
        XCTAssertEqual(
            SetupChecklist.summary(helper: .enabled(reachable: true), loginItem: .enabled, notificationsAuthorized: true),
            "Automatic repair is ready."
        )
    }

    func testLoginItemDoesNotBlockAutomaticRepairReadiness() {
        XCTAssertTrue(SetupChecklist.isReady(helper: .enabled(reachable: true), loginItem: .notRegistered))
        XCTAssertEqual(
            SetupChecklist.summary(helper: .enabled(reachable: true), loginItem: .notRegistered, notificationsAuthorized: true),
            "Automatic repair is ready."
        )
    }

    func testNoStepShoutsAtTheUser() {
        let states: [(RepairHelperState, LoginItemState, Bool)] = [
            (.notConfigured, .notRegistered, false),
            (.awaitingApproval, .requiresApproval, false),
            (.enabled(reachable: false), .notFound, true),
            (.enabled(reachable: true), .enabled, true),
            (.unavailable("something went sideways"), .unknown("odd"), false)
        ]
        for (helper, loginItem, notifications) in states {
            for step in SetupChecklist.steps(helper: helper, loginItem: loginItem, notificationsAuthorized: notifications) {
                XCTAssertFalse(step.title.isEmpty)
                XCTAssertFalse(step.detail.isEmpty)
                XCTAssertFalse(step.actionTitle.isEmpty)
                XCTAssertFalse(step.title.contains("!"))
                XCTAssertFalse(step.detail.contains("!"))
            }
        }
    }

    func testDismissalPersistsUntilAFullMinuteOfSuccessfulQuietCoverage() {
        let suite = "FennecTests-episode-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let signal = Date(timeIntervalSince1970: 1_000)
        var policy = FaultEpisodePolicy(defaults: defaults)
        let episodeID = policy.noteSignal(at: signal)
        policy.suppress(episodeID)

        var reopened = FaultEpisodePolicy(defaults: defaults)
        XCTAssertTrue(reopened.isCurrent(episodeID))
        XCTAssertFalse(reopened.mayPrompt(for: episodeID))

        // A failed query has no coverage callback, so the persisted dismissal
        // remains in force. Fifty-nine covered seconds are also insufficient.
        XCTAssertNil(reopened.observeSuccessfulCoverage(from: signal, through: signal.addingTimeInterval(59)))
        XCTAssertFalse(reopened.mayPrompt(for: episodeID))

        XCTAssertEqual(
            reopened.observeSuccessfulCoverage(
                from: signal.addingTimeInterval(59),
                through: signal.addingTimeInterval(60)
            ),
            episodeID
        )
        XCTAssertFalse(reopened.isCurrent(episodeID))

        let nextEpisodeID = reopened.noteSignal(at: signal.addingTimeInterval(61))
        XCTAssertNotEqual(nextEpisodeID, episodeID)
        XCTAssertTrue(reopened.mayPrompt(for: nextEpisodeID))
    }

    func testCoverageMustBeContiguousToRearmAnEpisode() {
        let suite = "FennecTests-episode-gap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let signal = Date(timeIntervalSince1970: 2_000)
        var policy = FaultEpisodePolicy(defaults: defaults)
        let episodeID = policy.noteSignal(at: signal)
        XCTAssertNil(policy.observeSuccessfulCoverage(from: signal, through: signal.addingTimeInterval(30)))
        XCTAssertNil(policy.observeSuccessfulCoverage(
            from: signal.addingTimeInterval(50),
            through: signal.addingTimeInterval(80)
        ))
        XCTAssertTrue(policy.isCurrent(episodeID))
    }

    func testAnOutputChangeInvalidatesTheOldDismissedEpisode() {
        let suite = "FennecTests-episode-output-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var policy = FaultEpisodePolicy(defaults: defaults)
        let oldID = policy.noteSignal(at: Date(timeIntervalSince1970: 3_000))
        policy.suppress(oldID)
        XCTAssertFalse(policy.mayPrompt(for: oldID))

        policy.invalidateForOutputChange()
        let nextID = policy.noteSignal(at: Date(timeIntervalSince1970: 3_001))

        XCTAssertNotEqual(nextID, oldID)
        XCTAssertTrue(policy.mayPrompt(for: nextID))
    }
}
