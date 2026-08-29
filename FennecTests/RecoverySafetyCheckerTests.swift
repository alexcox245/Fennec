import CoreAudio
import XCTest

/// The guard that decides whether an automatic repair is allowed to run.
///
/// These cover the field bug in T-038: `corespeechd` holds an input stream
/// permanently when "Hey Siri" or dictation is enabled, so the microphone
/// guard vetoed every automatic repair on the owner's Mac and posted "Crackle
/// repair skipped / Microphone input is active in corespeechd." while nothing
/// was recording.
final class RecoverySafetyCheckerTests: XCTestCase {
    private let checker = RecoverySafetyChecker()
    private let ownPID: pid_t = 4242

    private func process(
        pid: pid_t,
        bundleIdentifier: String = "",
        name: String,
        input: Bool = false,
        output: Bool = false
    ) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            objectID: AudioObjectID(pid),
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            processName: name,
            isRunningInput: input,
            isRunningOutput: output
        )
    }

    private func report(_ processes: [AudioProcessSnapshot]) -> RecoverySafetyReport {
        checker.report(
            for: processes,
            ownPID: ownPID,
            protectMicrophone: true,
            protectCommunicationApps: true
        )
    }

    // MARK: The wake-word daemon

    private var corespeechd: AudioProcessSnapshot {
        process(pid: 1053, bundleIdentifier: "com.apple.CoreSpeech", name: "corespeechd", input: true)
    }

    func testWakeWordDaemonDoesNotBlockARepair() {
        let result = report([corespeechd])
        XCTAssertTrue(result.canAutoRepair)
        XCTAssertEqual(result.blockers, [])
        XCTAssertEqual(result.activeInputProcesses, [])
    }

    /// The system variant is a different executable under the same bundle ID.
    func testSystemWakeWordDaemonDoesNotBlockARepair() {
        let daemon = process(
            pid: 453,
            bundleIdentifier: "com.apple.CoreSpeech",
            name: "corespeechd_system",
            input: true
        )
        XCTAssertTrue(report([daemon]).canAutoRepair)
    }

    /// The bundle identifier is the stable identity, but it does not always
    /// read back off a daemon's process object; the name has to hold on its own.
    func testWakeWordDaemonIsIgnoredWithoutABundleIdentifier() {
        let daemon = process(pid: 1053, name: "corespeechd", input: true)
        XCTAssertTrue(report([daemon]).canAutoRepair)
    }

    func testCoreAudioItselfDoesNotBlockARepair() {
        let daemon = process(pid: 300, name: "coreaudiod", input: true, output: true)
        XCTAssertTrue(report([daemon]).canAutoRepair)
    }

    func testFennecsOwnStreamDoesNotBlockARepair() {
        let mine = process(pid: ownPID, bundleIdentifier: "com.ludicrousdesigns.Fennec", name: "Fennec", input: true)
        XCTAssertTrue(report([mine]).canAutoRepair)
    }

    // MARK: What must still block

    func testARealRecordingStillBlocksARepair() {
        let app = process(pid: 900, bundleIdentifier: "com.apple.VoiceMemos", name: "Voice Memos", input: true)
        let result = report([app])
        XCTAssertFalse(result.canAutoRepair)
        XCTAssertEqual(result.blockers, ["Microphone input is active in Voice Memos."])
        XCTAssertEqual(result.activeInputProcesses, [app])
    }

    /// The exact shape of the false positive: the daemon is filtered, the
    /// person on the call is not.
    func testTheDaemonIsFilteredOutOfAMixedList() {
        let zoom = process(pid: 901, bundleIdentifier: "us.zoom.xos", name: "zoom.us", input: true, output: true)
        let spotify = process(pid: 1307, bundleIdentifier: "com.spotify.client", name: "Spotify", output: true)
        let result = report([corespeechd, zoom, spotify])

        XCTAssertFalse(result.canAutoRepair)
        XCTAssertEqual(result.activeInputProcesses, [zoom])
        XCTAssertEqual(result.blockers.count, 2)
        XCTAssertEqual(result.blockers[0], "Microphone input is active in zoom.us.")
        XCTAssertTrue(result.blockers[1].contains("zoom.us"))
    }

    /// Continuity and conferencing daemons open input only while something
    /// real is happening, so they are deliberately *not* in the ignore set.
    func testConferencingDaemonsStillBlock() {
        for name in ["avconferenced", "ContinuityCaptureAgent"] {
            let daemon = process(pid: 873, name: name, input: true)
            XCTAssertFalse(report([daemon]).canAutoRepair, "\(name) should still block a repair")
        }
    }

    func testPlaybackAloneNeverBlocks() {
        let spotify = process(pid: 1307, bundleIdentifier: "com.spotify.client", name: "Spotify", output: true)
        XCTAssertTrue(report([spotify]).canAutoRepair)
    }

    // MARK: The switches

    func testMicrophoneProtectionOffAllowsARealRecording() {
        let app = process(pid: 900, bundleIdentifier: "com.apple.VoiceMemos", name: "Voice Memos", input: true)
        let result = checker.report(
            for: [app],
            ownPID: ownPID,
            protectMicrophone: false,
            protectCommunicationApps: false
        )
        XCTAssertTrue(result.canAutoRepair)
    }

    /// A protected call app is caught by the second gate even when the
    /// microphone gate is switched off.
    func testProtectedAppBlocksOnOutputAlone() {
        let teams = process(pid: 902, bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams", output: true)
        let result = checker.report(
            for: [teams],
            ownPID: ownPID,
            protectMicrophone: false,
            protectCommunicationApps: true
        )
        XCTAssertFalse(result.canAutoRepair)
        XCTAssertEqual(result.blockers.count, 1)
        XCTAssertTrue(result.blockers[0].hasPrefix("A protected call or recording app is using audio:"))
    }

    func testAnEmptyMachineIsClear() {
        XCTAssertTrue(report([]).canAutoRepair)
        XCTAssertEqual(report([]).blockers, [])
    }

    /// A process with no name falls back to its bundle identifier rather than
    /// naming an empty string in a banner.
    func testUnnamedProcessIsNamedByBundleIdentifier() {
        let ghost = process(pid: 903, bundleIdentifier: "com.example.recorder", name: "", input: true)
        XCTAssertEqual(report([ghost]).blockers, ["Microphone input is active in com.example.recorder."])
    }
}
