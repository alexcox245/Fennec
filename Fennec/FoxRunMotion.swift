import CoreGraphics
import Foundation

/// Timing and geometry only: no window, timer, audio, or screen enumeration.
struct FoxRunCycle {
    let delays: [TimeInterval]
    let duration: TimeInterval
    /// Includes the boundary at 1; the renderer repeats frame zero there.
    let keyTimes: [Double]

    init?(delays: [TimeInterval]) {
        guard delays.count > 1, delays.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let duration = delays.reduce(0, +)
        guard duration.isFinite else { return nil }
        self.delays = delays
        self.duration = duration
        var elapsed: TimeInterval = 0
        self.keyTimes = [0] + delays.map {
            elapsed += $0
            return elapsed / duration
        }
    }
}

struct FoxRunMotion {
    /// The approved GIF's canvas and the union of all fourteen alpha bounds.
    /// Crop every frame identically; per-frame trimming would erase the hop.
    static let sourceSize = CGSize(width: 1147, height: 645)
    static let sourceBounds = CGRect(x: 40, y: 53, width: 1087, height: 544)
    static let preferredWidth: CGFloat = 240

    /// The near rear paw moves from about x=535 to x=755 between frames
    /// 3 and 6 (0.25 s) while close to the ground: ~880 source pixels/s.
    /// One 1.16 s loop therefore advances ~1021 source pixels. This is an
    /// artistic calibration, not a claim that every drawn paw is stationary.
    static let sourceStride: CGFloat = 1021

    let panelFrame: CGRect
    let spriteSize: CGSize
    let start: CGPoint
    let end: CGPoint
    let speed: CGFloat
    let duration: TimeInterval
    let cycleDuration: TimeInterval

    init?(
        screenFrame: CGRect,
        cycleDuration: TimeInterval,
        spriteWidth: CGFloat = preferredWidth,
        playbackRate: Double = 1
    ) {
        let bottomInset: CGFloat = 10
        guard [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
               spriteWidth].allSatisfy(\.isFinite),
              screenFrame.width > 0, screenFrame.height > bottomInset, spriteWidth > 0,
              cycleDuration.isFinite, cycleDuration > 0,
              playbackRate.isFinite, playbackRate > 0 else { return nil }

        let aspect = Self.sourceBounds.height / Self.sourceBounds.width
        let width = min(spriteWidth, screenFrame.width / 2, (screenFrame.height - bottomInset) / aspect)
        spriteSize = CGSize(width: width, height: width * aspect)
        // The strip spans the physical display, including the area occupied by the Dock.
        panelFrame = CGRect(
            x: screenFrame.minX, y: screenFrame.minY + bottomInset,
            width: screenFrame.width, height: ceil(spriteSize.height)
        )
        let margin: CGFloat = 16
        start = CGPoint(x: -width / 2 - margin, y: spriteSize.height / 2)
        end = CGPoint(x: screenFrame.width + width / 2 + margin, y: spriteSize.height / 2)
        self.cycleDuration = cycleDuration / playbackRate
        speed = Self.sourceStride * (width / Self.sourceBounds.width) / self.cycleDuration
        duration = (end.x - start.x) / speed
    }

    static func screenIndex(containing pointer: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(pointer) } ?? (frames.isEmpty ? nil : 0)
    }
}

/// A late decode/completion/failure must never resurrect a cancelled run or
/// dismiss a newer one. One current ticket; no queue of foxes to replay.
struct FoxRunLifecycle {
    private(set) var currentID: UUID?
    private var lastID: UUID?

    mutating func begin(_ id: UUID) -> Bool {
        guard currentID == nil, lastID != id else { return false }
        currentID = id
        lastID = id
        return true
    }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard currentID == id else { return false }
        currentID = nil
        return true
    }
}

/// A bounded queue for a user-initiated repair's foxes. Requests are admitted
/// once, so repeated clicks cannot turn into minutes of queued animation work.
struct RepairFoxBurst {
    static let maximumTotal = 100
    static let maximumVisible = 100
    /// A half-second cadence cannot put one hundred crossings on a normal display at once.
    static let minimumSpacing: TimeInterval = 0.04

    private(set) var accepted = 0
    private(set) var spawned = 0
    private(set) var active = 0
    private(set) var lastSpawnedAt: TimeInterval?

    mutating func request() -> Bool {
        guard accepted < Self.maximumTotal else { return false }
        accepted += 1
        return true
    }

    /// Nil means there is no pending request or no visible slot yet.
    func delayUntilNext(at now: TimeInterval) -> TimeInterval? {
        guard now.isFinite, spawned < accepted, active < Self.maximumVisible else { return nil }
        guard let lastSpawnedAt else { return 0 }
        return max(0, Self.minimumSpacing - (now - lastSpawnedAt))
    }

    mutating func spawn(at now: TimeInterval) -> Bool {
        guard delayUntilNext(at: now) == 0 else { return false }
        spawned += 1
        active += 1
        lastSpawnedAt = now
        return true
    }

    mutating func finish() {
        guard active > 0 else { return }
        active -= 1
    }

    mutating func reset() { self = Self() }
}
