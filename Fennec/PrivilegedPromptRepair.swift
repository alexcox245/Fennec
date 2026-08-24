import Foundation

enum PrivilegedPromptRepair {
    static func restartCoreAudio() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [
                    "-e",
                    "do shell script \"/usr/bin/killall -TERM coreaudiod\" with administrator privileges"
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
