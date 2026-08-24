import Foundation

enum PrivilegedPromptRepair {
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
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: "Core Audio restarted using administrator authorization.")
                    } else {
                        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let message = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw HelperCallError(
                            message: message?.isEmpty == false
                                ? message!
                                : "Administrator authorization was cancelled or the repair command failed."
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
