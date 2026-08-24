import Darwin
import Foundation

private struct HelperExecutionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class HelperService: NSObject, FennecHelperProtocol, NSXPCListenerDelegate {
    private let restartLock = NSLock()
    private var lastRestart = Date.distantPast
    private let minimumRestartInterval: TimeInterval = 20

    func configureAndResumeListener() throws -> NSXPCListener {
        let listener = NSXPCListener(machServiceName: AppConstants.helperMachServiceName)
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(
            try CodeSigningRequirement.peerRequirement(bundleIdentifier: AppConstants.appBundleIdentifier)
        )
        listener.resume()
        return listener
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: FennecHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        // Parseable rather than prose, so the app can tell whether the helper
        // running as root is the one that shipped with it. No protocol change:
        // the reply was always a String.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown"
        reply(HelperIdentity.format(build: build, path: path, euid: geteuid()))
    }

    func restartCoreAudio(withReply reply: @escaping (Bool, String) -> Void) {
        guard geteuid() == 0 else {
            reply(false, "The repair helper is not running as root.")
            return
        }

        restartLock.lock()
        let elapsed = Date().timeIntervalSince(lastRestart)
        if elapsed < minimumRestartInterval {
            let remaining = Int(ceil(minimumRestartInterval - elapsed))
            restartLock.unlock()
            reply(false, "Core Audio was restarted too recently. Try again in \(remaining) seconds.")
            return
        }
        lastRestart = Date()
        restartLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let previousPIDs = Self.runningCoreAudioPIDs()
                _ = try Self.run(
                    executable: "/usr/bin/killall",
                    arguments: ["-TERM", "coreaudiod"]
                )

                // launchd should immediately replace coreaudiod. Confirm that
                // at least one new process—not merely a still-exiting old PID—
                // appears before reporting success.
                let deadline = Date().addingTimeInterval(3)
                var replacementPIDs: Set<pid_t> = []
                repeat {
                    Thread.sleep(forTimeInterval: 0.15)
                    let currentPIDs = Self.runningCoreAudioPIDs()
                    let newPIDs = currentPIDs.subtracting(previousPIDs)
                    if !newPIDs.isEmpty || (previousPIDs.isEmpty && !currentPIDs.isEmpty) {
                        replacementPIDs = newPIDs.isEmpty ? currentPIDs : newPIDs
                        break
                    }
                } while Date() < deadline

                guard !replacementPIDs.isEmpty else {
                    throw HelperExecutionError(
                        message: "Core Audio was terminated, but launchd did not provide a confirmed replacement within 3 seconds."
                    )
                }

                reply(true, "Core Audio restarted successfully.")
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    private static func runningCoreAudioPIDs() -> Set<pid_t> {
        guard let output = try? run(
            executable: "/usr/bin/pgrep",
            arguments: ["-x", "coreaudiod"]
        ) else {
            return []
        }

        return Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            Int32(line.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    @discardableResult
    private static func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw HelperExecutionError(
                message: !stderr.isEmpty
                    ? stderr
                    : "\(executable) exited with status \(process.terminationStatus)."
            )
        }
        return stdout
    }
}
