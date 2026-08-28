import Foundation

enum DetectionSensitivity: String, CaseIterable, Codable, Identifiable {
    case conservative
    case balanced
    case immediate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .immediate: return "Immediate"
        }
    }

    /// One line under the picker. Says what Fennec waits for, in the same
    /// numbers the engine actually uses.
    var detail: String {
        switch self {
        case .conservative: return "Waits for 3 signals within 12 seconds. Fewest interruptions, longest crackle."
        case .balanced: return "Waits for 2 signals within 8 seconds. You hear the fault start, then it is gone."
        case .immediate: return "Acts on the 1st signal. Fastest, but a harmless blip can cost you a short audio gap."
        }
    }

    /// What the user actually hears under this setting: the honest version.
    var experience: String {
        switch self {
        case .conservative: return "You hear a few seconds of crackle."
        case .balanced: return "You hear about a second of crackle."
        case .immediate: return "You may hear nothing at all."
        }
    }

    var threshold: Int {
        switch self {
        case .conservative: return 3
        case .balanced: return 2
        case .immediate: return 1
        }
    }

    var window: TimeInterval {
        switch self {
        case .conservative: return 12
        case .balanced: return 8
        case .immediate: return 2
        }
    }
}

struct DetectionDecision: Equatable, Sendable {
    let signal: AudioSignalKind
    let reason: String
    let signalCount: Int
    /// Wall-clock span between the first and last signal in the window.
    /// Zero when they all landed inside one 250 ms drain.
    let elapsedSeconds: TimeInterval
    /// The configured window this decision was made under.
    let windowSeconds: TimeInterval
}

final class DetectionEngine {
    private var overloadDates: [Date] = []

    func ingest(_ batch: AudioSignalBatch, sensitivity: DetectionSensitivity) -> DetectionDecision? {
        if batch.abnormalStops > 0 {
            overloadDates.removeAll()
            return DetectionDecision(
                signal: .ioStoppedAbnormally,
                reason: "Core Audio reported that device I/O stopped abnormally.",
                signalCount: Int(batch.abnormalStops),
                elapsedSeconds: 0,
                windowSeconds: sensitivity.window
            )
        }

        guard batch.overloads > 0 else { return nil }
        if let trueDates = batch.overloadDates, !trueDates.isEmpty {
            // A polled witness reports events after the fact; window math on
            // the poll time instead of the event times would make the poll
            // interval, not the fault, decide whether a threshold is met.
            overloadDates.append(contentsOf: trueDates)
        } else {
            for _ in 0..<batch.overloads {
                overloadDates.append(batch.date)
            }
        }

        let cutoff = batch.date.addingTimeInterval(-sensitivity.window)
        overloadDates.removeAll { $0 < cutoff }

        guard overloadDates.count >= sensitivity.threshold else { return nil }
        let count = overloadDates.count
        // The span the user actually experienced, not the configured window.
        // "2 signals in 5.8 s" is a true statement; "within 8 seconds" is only
        // a description of the setting.
        let elapsed = (overloadDates.max() ?? batch.date)
            .timeIntervalSince(overloadDates.min() ?? batch.date)
        overloadDates.removeAll()
        return DetectionDecision(
            signal: .processorOverload,
            reason: "Core Audio missed its real-time output deadline \(count) time\(count == 1 ? "" : "s") within \(Int(sensitivity.window)) seconds.",
            signalCount: count,
            elapsedSeconds: elapsed,
            windowSeconds: sensitivity.window
        )
    }

    func reset() {
        overloadDates.removeAll()
    }
}
