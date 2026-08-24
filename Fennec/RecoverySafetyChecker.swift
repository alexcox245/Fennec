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

    func evaluate(
        protectMicrophone: Bool,
        protectCommunicationApps: Bool
    ) -> RecoverySafetyReport {
        do {
            let ownPID = getpid()
            let processes = try CoreAudioReader.activeAudioProcesses().filter { process in
                process.pid != ownPID && process.processName != "coreaudiod"
            }

            let inputProcesses = protectMicrophone
                ? processes.filter(\.isRunningInput)
                : []

            let protectedProcesses = protectCommunicationApps
                ? processes.filter { process in
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
        } catch {
            return RecoverySafetyReport(
                canAutoRepair: false,
                blockers: ["Fennec could not verify whether a call or recording is active: \(error.localizedDescription)"],
                activeInputProcesses: [],
                protectedAudioProcesses: []
            )
        }
    }

    private func uniqueNames(_ processes: [AudioProcessSnapshot]) -> [String] {
        Array(Set(processes.map { process in
            process.processName.isEmpty ? process.bundleIdentifier : process.processName
        })).sorted()
    }
}
