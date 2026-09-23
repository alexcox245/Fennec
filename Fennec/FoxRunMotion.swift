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
        visibleFrame: CGRect,
        cycleDuration: TimeInterval,
        spriteWidth: CGFloat = preferredWidth,
        playbackRate: Double = 1
    ) {
        let visible = screenFrame.intersection(visibleFrame)
        guard !visible.isNull, !visible.isEmpty,
              [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
               visible.minY, visible.height, spriteWidth].allSatisfy(\.isFinite),
              screenFrame.width > 0, screenFrame.height > 0, spriteWidth > 0,
              cycleDuration.isFinite, cycleDuration > 0,
              playbackRate.isFinite, playbackRate > 0 else { return nil }

        let bottomInset = min(CGFloat(12), visible.height / 4)
        let aspect = Self.sourceBounds.height / Self.sourceBounds.width
        let width = min(spriteWidth, screenFrame.width / 2, (visible.height - bottomInset) / aspect)
        spriteSize = CGSize(width: width, height: width * aspect)
        // The strip spans the physical display; the feet clear the Dock.
        panelFrame = CGRect(
            x: screenFrame.minX, y: visible.minY + bottomInset,
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
