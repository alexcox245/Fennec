import Foundation

/// The user dismissed the administrator prompt. Not a failure — a decision.
struct RepairCancelled: LocalizedError {
    var errorDescription: String? { "Administrator authorization was cancelled." }
}

enum PrivilegedPromptRepair {
    /// The `osascript` child, while one is running. Retained so quitting can
    /// terminate it rather than orphaning a SecurityAgent password dialog
    /// owned by a process that has exited.
    private nonisolated(unsafe) static var inFlight: Process?
    private static let inFlightLock = NSLock()

    static func cancelInFlight() {
        inFlightLock.lock()
        let process = inFlight
        inFlightLock.unlock()
        process?.terminate()
    }

    /// The exact command the administrator prompt will run. Shown to the user
    /// verbatim before they approve it, so the dialog is never a surprise and
    /// the disclosure can never drift from the behaviour.
    static let command = "/usr/bin/killall -TERM coreaudiod"

    static func restartCoreAudio() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [
                    "-e",
                    "do shell script \"\(command)\" with administrator privileges"
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errorPipe

                do {
                    inFlightLock.lock(); inFlight = process; inFlightLock.unlock()
                    defer {
                        inFlightLock.lock(); inFlight = nil; inFlightLock.unlock()
                    }
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: "Core Audio restarted using administrator authorization.")
                    } else {
                        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let message = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                        // -128 is errAEEventUserCancelled: the user pressed
                        // Cancel. Recording that as a permanent red failure
                        // with an alarm sound — and resetting the days-without-
                        // incident sign — punishes someone for declining.
                        if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
                            throw RepairCancelled()
                        }
                        throw HelperCallError(
                            message: message.isEmpty
                                ? "The administrator repair command failed."
                                : message
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
