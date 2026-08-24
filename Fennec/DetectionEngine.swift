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

    var detail: String {
        switch self {
        case .conservative: return "Repair after 3 overload signals within 12 seconds."
        case .balanced: return "Repair after 2 overload signals within 8 seconds."
        case .immediate: return "Repair after the first overload signal."
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
}

final class DetectionEngine {
    private var overloadDates: [Date] = []

    func ingest(_ batch: AudioSignalBatch, sensitivity: DetectionSensitivity) -> DetectionDecision? {
        if batch.abnormalStops > 0 {
            overloadDates.removeAll()
            return DetectionDecision(
                signal: .ioStoppedAbnormally,
                reason: "Core Audio reported that device I/O stopped abnormally.",
                signalCount: Int(batch.abnormalStops)
            )
        }

        guard batch.overloads > 0 else { return nil }
        for _ in 0..<batch.overloads {
            overloadDates.append(batch.date)
        }

        let cutoff = batch.date.addingTimeInterval(-sensitivity.window)
        overloadDates.removeAll { $0 < cutoff }

        guard overloadDates.count >= sensitivity.threshold else { return nil }
        let count = overloadDates.count
        overloadDates.removeAll()
        return DetectionDecision(
            signal: .processorOverload,
            reason: "Core Audio missed its real-time output deadline \(count) time\(count == 1 ? "" : "s") within \(Int(sensitivity.window)) seconds.",
            signalCount: count
        )
    }

    func reset() {
        overloadDates.removeAll()
    }
}
