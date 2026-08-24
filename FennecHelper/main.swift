import Darwin
import Foundation

let service = HelperService()

do {
    let listener = try service.configureAndResumeListener()
    withExtendedLifetime(listener) {
        RunLoop.current.run()
    }
} catch {
    fputs("FennecHelper failed to start: \(error.localizedDescription)\n", stderr)
    exit(EX_CONFIG)
}
