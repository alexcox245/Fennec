import XCTest

/// The checklist decides what the popover and the first-run window ask the
/// user to do. Getting it wrong means either nagging someone who is already
/// set up, or quietly leaving Fennec unable to do its job.
final class SetupChecklistTests: XCTestCase {

    private func remaining(
        helper: RepairHelperState = .notConfigured,
        loginItem: LoginItemState = .notRegistered,
        notifications: Bool = false,
        location: InstallLocation = .applications
    ) -> [SetupStep] {
        SetupChecklist.remaining(
            helper: helper,
            loginItem: loginItem,
            notificationsAuthorized: notifications,
            location: location
        )
    }

    func testAFreshInstallHasEverythingLeftToDo() {
        let steps = remaining()
        XCTAssertEqual(steps.map(\.kind), [.helper, .loginItem, .notifications])
    }

    func testRequiredStepsSortAheadOfOptionalOnes() {
        // Notifications are nice; without the helper Fennec cannot repair at
        // all. The blocking work has to be the first thing the user sees.
        let steps = remaining(helper: .notConfigured, loginItem: .notRegistered, notifications: false)
        let firstOptional = steps.firstIndex { !$0.isRequired } ?? steps.count
        let lastRequired = steps.lastIndex { $0.isRequired } ?? -1
        XCTAssertLessThan(lastRequired, firstOptional)
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

    func testADevelopmentBuildIsNotedButNotRequired() throws {
        let steps = remaining(location: .developmentBuild)
        let install = try XCTUnwrap(steps.first { $0.kind == .install })
        XCTAssertFalse(install.isRequired)
    }

    // MARK: Helper states

    func testAnInstalledButUnresponsiveHelperIsNotComplete() throws {
        let steps = remaining(helper: .enabled(reachable: false))
        let helperStep = try XCTUnwrap(steps.first { $0.kind == .helper })
        // The action rebuilds the registration — the fix — rather than
        // re-pinging a daemon that cannot answer and calling it a day.
        XCTAssertEqual(helperStep.actionTitle, "Rebuild")
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
        let step = try XCTUnwrap(remaining(loginItem: .requiresApproval).first { $0.kind == .loginItem })
        XCTAssertEqual(step.actionTitle, "Open Login Items…")
    }

    func testAnUnregisteredLoginItemOffersToTurnItOn() throws {
        let step = try XCTUnwrap(remaining(loginItem: .notRegistered).first { $0.kind == .loginItem })
        XCTAssertEqual(step.actionTitle, "Turn On")
        XCTAssertTrue(step.isRequired, "Fennec has to already be running to catch the first signal.")
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

    func testReadinessNeedsBothTheHelperAndTheLoginItem() {
        XCTAssertTrue(SetupChecklist.isReady(helper: .enabled(reachable: true), loginItem: .enabled))
        XCTAssertFalse(SetupChecklist.isReady(helper: .enabled(reachable: true), loginItem: .notRegistered))
        XCTAssertFalse(SetupChecklist.isReady(helper: .enabled(reachable: false), loginItem: .enabled))
        XCTAssertFalse(SetupChecklist.isReady(helper: .notConfigured, loginItem: .enabled))
    }

    func testSummaryCountsOnlyBlockingWork() {
        XCTAssertEqual(
            SetupChecklist.summary(helper: .notConfigured, loginItem: .notRegistered, notificationsAuthorized: false),
            "2 steps left before Fennec can repair on its own."
        )
        XCTAssertEqual(
            SetupChecklist.summary(helper: .enabled(reachable: true), loginItem: .enabled, notificationsAuthorized: false),
            "Fennec will repair automatically. 1 optional step left."
        )
        XCTAssertEqual(
            SetupChecklist.summary(helper: .enabled(reachable: true), loginItem: .enabled, notificationsAuthorized: true),
            "Fennec is set up. It starts with your Mac and repairs without asking."
        )
    }

    func testSummarySingularisesOneRemainingStep() {
        XCTAssertEqual(
            SetupChecklist.summary(helper: .enabled(reachable: true), loginItem: .notRegistered, notificationsAuthorized: true),
            "1 step left before Fennec can repair on its own."
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
}
