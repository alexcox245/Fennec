import Foundation

/// The stall verdict: audio keeps stopping and starting because the Mac is
/// starved, and restarting Core Audio will not help.
///
/// This is a different animal from the crackle fault. Diagnosed live: under a
/// load average of 17–25 with swap nearly full, Spotify's process sat in
/// uninterruptible page-in waits, its buffer drained, and `coreaudiod` logged
/// a *clean* `StopIO` → `StartIO` pair every 30–90 seconds — zero overloads.
/// Nothing is wrong with Core Audio, so Fennec's one repair is the wrong
/// tool, and the honest move is to say so once instead of staying silent
/// while the user wonders why the fox hears nothing.
struct StallAdvisory: Equatable, Sendable {
    let stopCount: Int
    let windowSeconds: TimeInterval
    let loadPerCore: Double
    let memoryPressureLevel: Int

    var memoryPressureLabel: String {
        switch memoryPressureLevel {
        case ..<2: return "normal"
        case 2, 3: return "warning"
        default: return "critical"
        }
    }
}

enum StallAdvisor {
    /// How far back a stop still counts toward the pattern.
    static let window: TimeInterval = 180
    /// One clean stop is a song ending; two is a pause and a play. Three
    /// stops inside three minutes is playback fighting for its life.
    static let minimumStops = 3
    /// Load average per core above which the machine counts as busy. 1.0 is
    /// full occupancy; 1.25 means work is queueing.
    static let loadPerCoreThreshold = 1.25
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static let memoryPressureFloor = 2

    /// The pattern alone is not enough — a person toggling pause three times
    /// produces the same stops. The advisory requires the *cause* to be
    /// visible too: a starved machine.
    static func assess(
        stopDates: [Date],
        now: Date,
        loadPerCore: Double,
        memoryPressureLevel: Int
    ) -> StallAdvisory? {
        let cutoff = now.addingTimeInterval(-window)
        let recent = stopDates.filter { $0 >= cutoff }
        guard recent.count >= minimumStops else { return nil }
        guard loadPerCore >= loadPerCoreThreshold || memoryPressureLevel >= memoryPressureFloor else {
            return nil
        }
        return StallAdvisory(
            stopCount: recent.count,
            windowSeconds: window,
            loadPerCore: loadPerCore,
            memoryPressureLevel: memoryPressureLevel
        )
    }
}

/// The two starvation readings, sampled where the advisory is decided.
/// Kept apart from `StallAdvisor.assess` so the decision stays pure and
/// testable.
enum SystemLoadSampler {
    static func loadPerCore() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) >= 1 else { return 0 }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return loads[0] / Double(cores)
    }

    static func memoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return 1
        }
        return Int(level)
    }
}
