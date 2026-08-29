import Darwin
import Foundation

struct RecoverySafetyReport: Equatable, Sendable {
    let canAutoRepair: Bool
    let blockers: [String]
    let activeInputProcesses: [AudioProcessSnapshot]
    let protectedAudioProcesses: [AudioProcessSnapshot]

    static let clear = RecoverySafetyReport(
        canAutoRepair: true,
        blockers: [],
        activeInputProcesses: [],
        protectedAudioProcesses: []
    )
}

struct RecoverySafetyChecker: Sendable {
    private let protectedBundleIdentifiers: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.QuickTimePlayerX",
        "com.cisco.webexmeetingsapp",
        "com.hnc.Discord",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.obsproject.obs-studio",
        "com.skype.skype",
        "com.tinyspeck.slackmacgap",
        "us.zoom.xos"
    ]

    /// Processes whose input stream is not a microphone anyone is talking
    /// into, and which therefore must never veto a repair.
    ///
    /// `kAudioProcessPropertyIsRunningInput` answers "does this process hold
    /// an input stream", which is not the question the microphone guard is
    /// actually asking. `corespeechd` is Apple's wake-word daemon: with "Hey
    /// Siri" or dictation enabled it opens an input stream at login and never
    /// closes it, so the property reads true forever. macOS does not light
    /// the orange privacy indicator for it, precisely because nothing is
    /// being recorded, and the user is correct when they say their microphone
    /// is off.
    ///
    /// Left unfiltered this is not a nuisance, it is a total failure of the
    /// feature: on any Mac with Siri enabled the guard vetoes *every*
    /// automatic repair, forever, and says a microphone is live while doing
    /// it. Measured on the owner's machine before this fix, `corespeechd` was
    /// the sole holder of an input stream across repeated samples with no app
    /// recording anything.
    ///
    /// Matched on bundle identifier because that is the stable identity;
    /// `corespeechd` and `corespeechd_system` are separate executables
    /// sharing `com.apple.CoreSpeech`. The names are a fallback for when the
    /// bundle identifier does not read back.
    ///
    /// Deliberately narrow. Every other Apple audio daemon observed
    /// (`avconferenced`, `ContinuityCaptureAgent`, `assistantd`) opens input
    /// only while something real is happening, and blocking a repair during
    /// those is the guard working as intended. Add to this set only with a
    /// measurement showing a permanently held stream.
    private let alwaysOnInputBundleIdentifiers: Set<String> = [
        "com.apple.CoreSpeech"
    ]

    private let ignoredProcessNames: Set<String> = [
        // Restarting Core Audio is precisely what Fennec is asking for; the
        // daemon's own streams are not a reason to refuse.
        "coreaudiod",
        "corespeechd",
        "corespeechd_system"
    ]

    func evaluate(
        protectMicrophone: Bool,
        protectCommunicationApps: Bool
    ) -> RecoverySafetyReport {
        do {
            return report(
                for: try CoreAudioReader.activeAudioProcesses(),
                ownPID: getpid(),
                protectMicrophone: protectMicrophone,
                protectCommunicationApps: protectCommunicationApps
            )
        } catch {
            return RecoverySafetyReport(
                canAutoRepair: false,
                blockers: ["Fennec could not verify whether a call or recording is active: \(error.localizedDescription)"],
                activeInputProcesses: [],
                protectedAudioProcesses: []
            )
        }
    }

    /// The whole decision, as a pure function of a process list. Split out
    /// from the Core Audio read so the filtering that produced a false
    /// "microphone is active" banner in the field is under test.
    func report(
        for processes: [AudioProcessSnapshot],
        ownPID: pid_t,
        protectMicrophone: Bool,
        protectCommunicationApps: Bool
    ) -> RecoverySafetyReport {
        let candidates = processes.filter { process in
            process.pid != ownPID && !isIgnored(process)
        }

        let inputProcesses = protectMicrophone
            ? candidates.filter(\.isRunningInput)
            : []

        let protectedProcesses = protectCommunicationApps
            ? candidates.filter { process in
                guard process.isRunningInput || process.isRunningOutput else { return false }
                return protectedBundleIdentifiers.contains(process.bundleIdentifier)
            }
            : []

        var blockers: [String] = []
        if !inputProcesses.isEmpty {
            let names = uniqueNames(inputProcesses)
            blockers.append("Microphone input is active in \(names.joined(separator: ", ")).")
        }
        if !protectedProcesses.isEmpty {
            let names = uniqueNames(protectedProcesses)
            blockers.append("A protected call or recording app is using audio: \(names.joined(separator: ", ")).")
        }

        return RecoverySafetyReport(
            canAutoRepair: blockers.isEmpty,
            blockers: blockers,
            activeInputProcesses: inputProcesses,
            protectedAudioProcesses: protectedProcesses
        )
    }

    private func isIgnored(_ process: AudioProcessSnapshot) -> Bool {
        alwaysOnInputBundleIdentifiers.contains(process.bundleIdentifier)
            || ignoredProcessNames.contains(process.processName)
    }

    private func uniqueNames(_ processes: [AudioProcessSnapshot]) -> [String] {
        Array(Set(processes.map { process in
            process.processName.isEmpty ? process.bundleIdentifier : process.processName
        })).sorted()
    }
}
