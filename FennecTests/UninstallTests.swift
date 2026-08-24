import XCTest

/// The failure this guards: drag Fennec to the Trash and the root LaunchDaemon
/// stays registered. It is demonstrable in thirty seconds with no special
/// knowledge, and it is the single most damaging thing anyone can show about
/// an app that asks for root.
final class UninstallPlanTests: XCTestCase {

    private func steps(
        helper: Bool = true,
        loginItem: Bool = true,
        keepLogs: Bool = false,
        bundle: Bool = true
    ) -> [UninstallPlan.Step] {
        UninstallPlan.steps(
            helperInstalled: helper,
            loginItemEnabled: loginItem,
            keepLogs: keepLogs,
            canRemoveBundle: bundle
        )
    }

    func testAFullInstallRemovesEverythingInOrder() {
        XCTAssertEqual(
            steps().map(\.kind),
            [.helper, .loginItem, .supportFiles, .preferences, .bundle]
        )
    }

    func testTheHelperIsAlwaysTheFirstThingRemoved() {
        // It is the only step with root behind it, and the only one a user
        // cannot undo themselves from the Finder.
        XCTAssertEqual(steps().first?.kind, .helper)
    }

    func testTheHelperStepNamesTheTrapItExistsFor() throws {
        let step = try XCTUnwrap(steps().first { $0.kind == .helper })
        XCTAssertTrue(
            step.detail.contains("drag Fennec to the Trash"),
            "The user has to be told why this step is not optional."
        )
    }

    func testStepsThatWouldDoNothingAreOmitted() {
        XCTAssertFalse(steps(helper: false).contains { $0.kind == .helper })
        XCTAssertFalse(steps(loginItem: false).contains { $0.kind == .loginItem })
        XCTAssertFalse(steps(bundle: false).contains { $0.kind == .bundle })
    }

    func testKeepingLogsSkipsOnlyTheSupportFolder() {
        let kept = steps(keepLogs: true)
        XCTAssertFalse(kept.contains { $0.kind == .supportFiles })
        XCTAssertTrue(kept.contains { $0.kind == .helper })
        XCTAssertTrue(kept.contains { $0.kind == .preferences })
    }

    func testPreferencesAreAlwaysForgotten() {
        // There is no configuration in which leaving them behind is useful.
        XCTAssertTrue(steps(helper: false, loginItem: false, keepLogs: true, bundle: false)
            .contains { $0.kind == .preferences })
    }

    func testTheSummaryChangesWithTheLogChoice() {
        XCTAssertTrue(UninstallPlan.summary(keepLogs: true).contains("stay where they are"))
        XCTAssertTrue(UninstallPlan.summary(keepLogs: false).contains("delete"))
        for keep in [true, false] {
            XCTAssertTrue(UninstallPlan.summary(keepLogs: keep).contains("root helper"))
            XCTAssertFalse(UninstallPlan.summary(keepLogs: keep).contains("!"))
        }
    }

    func testTheManualFallbackRemovesTheDaemonAndTheFiles() {
        let fallback = UninstallPlan.manualFallback
        XCTAssertTrue(fallback.contains("launchctl bootout"))
        XCTAssertTrue(fallback.contains(AppConstants.helperBundleIdentifier))
        XCTAssertTrue(fallback.contains("defaults delete"))
    }

    func testEveryStepHasAReadableTitleAndDetail() {
        for step in steps() {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.detail.isEmpty)
            XCTAssertFalse(step.title.contains("!"))
        }
    }
}

/// After an in-place update the root process may still be the previous binary,
/// and `ping` used to reply with prose that had no version in it — so the
/// app's whole vocabulary for that was "Enabled, not responding".
final class HelperIdentityTests: XCTestCase {

    func testAWellFormedReplyParsesCompletely() {
        let identity = HelperIdentity.parse("ready euid=0 build=7 path=/Applications/Fennec.app/Contents/MacOS/FennecHelper")
        XCTAssertEqual(identity.build, "7")
        XCTAssertEqual(identity.euid, 0)
        XCTAssertEqual(identity.executablePath, "/Applications/Fennec.app/Contents/MacOS/FennecHelper")
        XCTAssertTrue(identity.isRoot)
    }

    func testFormatAndParseRoundTrip() {
        let formatted = HelperIdentity.format(build: "12", path: "/tmp/FennecHelper", euid: 0)
        let identity = HelperIdentity.parse(formatted)
        XCTAssertEqual(identity.build, "12")
        XCTAssertEqual(identity.executablePath, "/tmp/FennecHelper")
        XCTAssertEqual(identity.euid, 0)
    }

    func testAnUnparseableReplyStillSurvives() {
        // A helper from a much older build replies in prose. The panel must
        // show something true rather than an empty row.
        let identity = HelperIdentity.parse("Fennec helper ready (euid 0).")
        XCTAssertNil(identity.build)
        XCTAssertNil(identity.executablePath)
        XCTAssertEqual(identity.description, "Fennec helper ready (euid 0).")
    }

    func testANonRootHelperIsNotDescribedAsRoot() {
        let identity = HelperIdentity.parse("ready euid=501 build=7 path=/tmp/FennecHelper")
        XCTAssertFalse(identity.isRoot)
        XCTAssertFalse(identity.description.contains("running as root"))
    }

    func testMatchingBuildsReportNoMismatch() {
        let identity = HelperIdentity.parse("ready euid=0 build=7 path=/x")
        XCTAssertNil(identity.mismatch(againstAppBuild: "7"))
    }

    func testAStaleHelperIsNamedWithBothBuildNumbers() throws {
        let identity = HelperIdentity.parse("ready euid=0 build=1 path=/x")
        let mismatch = try XCTUnwrap(identity.mismatch(againstAppBuild: "7"))
        XCTAssertTrue(mismatch.contains("build 1"))
        XCTAssertTrue(mismatch.contains("build 7"))
        XCTAssertTrue(mismatch.contains("re-enable"), "It has to say what to do about it.")
    }

    func testUnknownVersionsNeverClaimAMismatch() {
        XCTAssertNil(HelperIdentity.parse("ready euid=0 path=/x").mismatch(againstAppBuild: "7"))
        XCTAssertNil(HelperIdentity.parse("ready euid=0 build=7 path=/x").mismatch(againstAppBuild: nil))
    }

    func testMalformedTokensAreIgnoredRatherThanCrashing() {
        // `path=` is deliberately the remainder, so a path containing spaces
        // survives. That means `path=` must be last — which `format` enforces.
        let identity = HelperIdentity.parse("ready = =0 build= euid=notanumber path=/x")
        XCTAssertNil(identity.euid)
        XCTAssertNil(identity.build.flatMap { $0.isEmpty ? nil : $0 })
        XCTAssertEqual(identity.executablePath, "/x")
    }

    func testFormatKeepsThePathLastBecauseTheParserTreatsItAsTheRemainder() {
        let formatted = HelperIdentity.format(build: "7", path: "/a b/c", euid: 0)
        XCTAssertTrue(formatted.hasSuffix("path=/a b/c"))
    }
}
