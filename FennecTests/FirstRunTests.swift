import XCTest

/// `SMAppService` binds its registration to the app's bundle path, so a helper
/// enabled from `~/Downloads` breaks the moment the app is moved, and the
/// only symptom Fennec can show for that is "Enabled, not responding".
final class InstallLocationTests: XCTestCase {
    private func classify(_ path: String) -> InstallLocation {
        InstallLocation.classify(URL(fileURLWithPath: path))
    }

    func testApplicationsFolderIsSupported() {
        XCTAssertEqual(classify("/Applications/Fennec.app"), .applications)
        XCTAssertTrue(classify("/Applications/Fennec.app").isSupported)
        XCTAssertNil(classify("/Applications/Fennec.app").warning)
    }

    func testPerUserApplicationsFolderIsAlsoSupported() {
        XCTAssertEqual(classify("/Users/someone/Applications/Fennec.app"), .applications)
    }

    func testAnApplicationsFolderOutsideUsersIsNotSpecial() {
        // /Volumes/Backup/Applications is a copy, not an install location.
        XCTAssertFalse(classify("/Volumes/Backup/Applications/Fennec.app").isSupported)
    }

    func testDerivedDataIsRecognisedAsADevelopmentBuild() {
        let location = classify("/Users/dev/Library/Developer/Xcode/DerivedData/Fennec-abc/Build/Products/Debug/Fennec.app")
        XCTAssertEqual(location, .developmentBuild)
        XCTAssertTrue(location.isSupported, "Nagging during development is noise, not a guard.")
        XCTAssertNotNil(location.warning, "But it should still say the registration is not durable.")
    }

    func testABuildProductsFolderAnywhereCountsAsDevelopment() {
        XCTAssertEqual(classify("/Users/dev/proj/build/DerivedData/Build/Products/Release/Fennec.app"), .developmentBuild)
    }

    func testDownloadsIsCalledOutByName() throws {
        let home = NSHomeDirectory()
        let location = classify("\(home)/Downloads/Fennec.app")
        guard case .elsewhere(let folder) = location else {
            return XCTFail("Expected .elsewhere, got \(location)")
        }
        XCTAssertEqual(folder, "~/Downloads")
        XCTAssertFalse(location.isSupported)
        let warning = try XCTUnwrap(location.warning)
        XCTAssertTrue(warning.contains("~/Downloads"))
        XCTAssertTrue(warning.contains("Applications"), "The warning has to say what to do about it.")
    }

    func testAnAbsolutePathOutsideHomeIsReportedVerbatim() {
        guard case .elsewhere(let folder) = classify("/opt/tools/Fennec.app") else {
            return XCTFail("Expected .elsewhere")
        }
        XCTAssertEqual(folder, "/opt/tools")
    }

    func testEveryUnsupportedLocationOffersAnAction() {
        for location in [classify("\(NSHomeDirectory())/Desktop/Fennec.app"), classify("/tmp/Fennec.app")] {
            XCTAssertNotNil(location.warning)
            XCTAssertNotNil(location.actionTitle)
        }
        XCTAssertNil(classify("/Applications/Fennec.app").actionTitle)
    }
}

/// The disclosure is the product's honesty, in text. A panel that enumerates
/// only the XPC surface is a true statement engineered to mislead, because
/// there is a second privileged path.
final class PrivilegeDisclosureTests: XCTestCase {
    func testAllThreePrivilegedPathsAreListed() {
        let ids = PrivilegeDisclosure.privilegedActions.map(\.id)
        XCTAssertEqual(ids, ["helper", "command", "prompt"])
    }

    func testTheAdministratorPromptIsDisclosedNotOmitted() throws {
        let item = try XCTUnwrap(PrivilegeDisclosure.privilegedActions.first { $0.id == "prompt" })
        XCTAssertTrue(item.detail.contains("password"))
        XCTAssertTrue(
            item.detail.contains("asks you first"),
            "The whole point is that this never happens unannounced."
        )
    }

    func testTheDisclosedCommandIsTheCommandThatRuns() throws {
        let item = try XCTUnwrap(PrivilegeDisclosure.privilegedActions.first { $0.id == "command" })
        XCTAssertEqual(item.code, PrivilegedPromptRepair.command)
    }

    func testTheXPCSurfaceIsNamedExactly() throws {
        let item = try XCTUnwrap(PrivilegeDisclosure.privilegedActions.first { $0.id == "helper" })
        let code = try XCTUnwrap(item.code)
        XCTAssertTrue(code.contains("ping"))
        XCTAssertTrue(code.contains("restartCoreAudio"))
    }

    func testTheCostAndTheLimitationAreBothStated() {
        let ids = PrivilegeDisclosure.facts.map(\.id)
        XCTAssertTrue(ids.contains("cost"), "A repair silences all audio; that is not a footnote.")
        XCTAssertTrue(ids.contains("limitation"), "Fennec detects the signal, not the sound.")
        XCTAssertTrue(ids.contains("network"))
        XCTAssertTrue(ids.contains("files"))
    }

    func testTheShellAliasQuestionIsAnswered() {
        // The target user can type `sudo killall coreaudiod`. If the product
        // never says what it adds beyond that, it has no argument.
        let answer = PrivilegeDisclosure.whyNotAShellAlias
        XCTAssertTrue(answer.contains("one command"))
        XCTAssertFalse(answer.isEmpty)
        XCTAssertFalse(answer.contains("!"))
    }

    func testTheThreeReasonsAStatusItemGoesMissingAreCovered() {
        let ids = PrivilegeDisclosure.missingFromMenuBar.map(\.id)
        XCTAssertEqual(Set(ids), ["manager", "notch", "dragged"])
    }

    func testNoDisclosureCopyShoutsOrIsEmpty() {
        let all = PrivilegeDisclosure.privilegedActions
            + PrivilegeDisclosure.facts
            + PrivilegeDisclosure.missingFromMenuBar
        for item in all {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.detail.isEmpty)
            XCTAssertFalse(item.title.contains("!"))
            XCTAssertFalse(item.detail.contains("!"))
        }
    }
}

/// First run has to be sticky in one direction only: it stops appearing once
/// the user has dismissed it, and never starts again on its own.
@MainActor
final class FirstRunPreferenceTests: XCTestCase {
    private var defaults = UserDefaults.standard
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "FennecTests-firstrun-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFirstLaunchHasNotCompletedFirstRun() {
        XCTAssertFalse(SettingsStore(defaults: defaults).hasCompletedFirstRun)
    }

    func testCompletionPersistsAcrossRelaunch() {
        let store = SettingsStore(defaults: defaults)
        store.hasCompletedFirstRun = true
        XCTAssertTrue(SettingsStore(defaults: defaults).hasCompletedFirstRun)
    }

    func testAutomaticRepairDefaultsOnAndBalancedIsTheDefaultThreshold() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.autoRepairEnabled)
        XCTAssertEqual(store.sensitivity, .balanced)
        XCTAssertTrue(store.notifyOnRepair)
        XCTAssertEqual(store.cooldownSeconds, 45)
    }

    func testTheSafetyDefaultsAreAllProtective() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.protectMicrophone)
        XCTAssertTrue(store.protectCommunicationApps)
        XCTAssertTrue(store.skipBluetooth)
    }

    func testStoredValuesWinOverDefaults() {
        defaults.set(false, forKey: "autoRepairEnabled")
        defaults.set("immediate", forKey: "sensitivity")
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.autoRepairEnabled)
        XCTAssertEqual(store.sensitivity, .immediate)
    }

    func testAnUnrecognisedSensitivityFallsBackToBalanced() {
        defaults.set("aggressive", forKey: "sensitivity")
        XCTAssertEqual(SettingsStore(defaults: defaults).sensitivity, .balanced)
    }
}
