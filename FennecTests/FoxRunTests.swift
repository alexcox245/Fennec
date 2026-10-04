import CoreGraphics
import XCTest

final class FoxRunTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private func motion(width: CGFloat = 240, rate: Double = 1) throws -> FoxRunMotion {
        try XCTUnwrap(FoxRunMotion(screenFrame: screen, cycleDuration: 1.16,
                                 spriteWidth: width, playbackRate: rate))
    }

    func testStartsAndEndsWithTheEntireFoxOutsideTheDisplay() throws {
        let run = try motion()
        XCTAssertLessThan(run.start.x + run.spriteSize.width / 2, 0)
        XCTAssertGreaterThan(run.end.x - run.spriteSize.width / 2, screen.width)
        XCTAssertEqual(run.duration * run.speed, run.end.x - run.start.x, accuracy: 0.001)
    }

    func testWiderDisplayAddsTravelWithoutChangingTheGaitOrSpeed() throws {
        let normal = try motion()
        let wide = try XCTUnwrap(FoxRunMotion(
            screenFrame: CGRect(x: -3440, y: -200, width: 3440, height: 1440),
            cycleDuration: 1.16
        ))
        XCTAssertEqual(wide.speed, normal.speed)
        XCTAssertEqual(wide.cycleDuration, normal.cycleDuration)
        XCTAssertEqual(wide.duration - normal.duration, 2000 / normal.speed, accuracy: 0.001)
        XCTAssertEqual(wide.panelFrame.minX, -3440)
        XCTAssertEqual(wide.panelFrame.minY, -190)
    }

    func testFeetAreTenPointsAbovePhysicalBottomAndStripReachesBothEdges() throws {
        let run = try motion()
        XCTAssertEqual(run.panelFrame.minY, screen.minY + 10)
        XCTAssertEqual(run.panelFrame.minX, screen.minX)
        XCTAssertEqual(run.panelFrame.maxX, screen.maxX)
        XCTAssertLessThanOrEqual(run.panelFrame.maxY, screen.maxY)
    }

    func testStrideScalesWithFoxSize() throws {
        let full = try motion()
        let small = try motion(width: 120)
        XCTAssertEqual(full.speed, small.speed * 2, accuracy: 0.001)
        XCTAssertEqual(full.speed * full.cycleDuration,
                       FoxRunMotion.sourceStride * 240 / FoxRunMotion.sourceBounds.width, accuracy: 0.001)
    }

    func testRetimingChangesFeetAndTravelTogether() throws {
        let normal = try motion()
        let fast = try motion(rate: 1.5)
        XCTAssertEqual(fast.speed, normal.speed * 1.5, accuracy: 0.001)
        XCTAssertEqual(fast.cycleDuration, normal.cycleDuration / 1.5, accuracy: 0.001)
        XCTAssertEqual(fast.duration, normal.duration / 1.5, accuracy: 0.001)
    }

    func testPointerSelectsDisplayWithNegativeOrVerticalOrigin() {
        let frames = [screen, CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                      CGRect(x: 0, y: 900, width: 1440, height: 900)]
        XCTAssertEqual(FoxRunMotion.screenIndex(containing: CGPoint(x: -500, y: 100), frames: frames), 1)
        XCTAssertEqual(FoxRunMotion.screenIndex(containing: CGPoint(x: 500, y: 1000), frames: frames), 2)
        XCTAssertEqual(FoxRunMotion.screenIndex(containing: CGPoint(x: 5000, y: 0), frames: frames), 0)
        XCTAssertNil(FoxRunMotion.screenIndex(containing: .zero, frames: []))
    }

    func testInvalidGeometryAndTimingNeverProduceAnAnimation() {
        XCTAssertNil(FoxRunMotion(screenFrame: .zero, cycleDuration: 1.16))
        for invalid in [0, -1, Double.nan, Double.infinity] {
            XCTAssertNil(FoxRunMotion(screenFrame: screen, cycleDuration: invalid))
            XCTAssertNil(FoxRunMotion(screenFrame: screen, cycleDuration: 1.16, playbackRate: invalid))
            XCTAssertNil(FoxRunCycle(delays: [0.08, invalid]))
        }
        XCTAssertNil(FoxRunCycle(delays: []))
    }

    func testUnequalFrameDelaysArePreservedIncludingLastFrame() throws {
        let cycle = try XCTUnwrap(FoxRunCycle(delays: [0.08, 0.09, 0.08]))
        XCTAssertEqual(cycle.duration, 0.25, accuracy: 0.00001)
        for (actual, expected) in zip(cycle.keyTimes, [0, 0.32, 0.68, 1]) {
            XCTAssertEqual(actual, expected, accuracy: 0.00001)
        }
    }

    func testOverlappingAndDuplicateAttemptsDoNotQueueAnotherFox() {
        var state = FoxRunLifecycle()
        let first = UUID(), second = UUID()
        XCTAssertTrue(state.begin(first))
        XCTAssertFalse(state.begin(first))
        XCTAssertFalse(state.begin(second))
        XCTAssertTrue(state.finish(first))
        XCTAssertFalse(state.begin(first), "A duplicate completion must not replay the same attempt.")
        XCTAssertTrue(state.begin(second))
    }

    func testLateCancellationOrCompletionCannotRemoveANewerCrossing() {
        var state = FoxRunLifecycle()
        let old = UUID(), new = UUID()
        XCTAssertTrue(state.begin(old))
        XCTAssertTrue(state.finish(old))
        XCTAssertTrue(state.begin(new))
        XCTAssertFalse(state.finish(old))
        XCTAssertEqual(state.currentID, new)
        XCTAssertTrue(state.finish(new))
        XCTAssertNil(state.currentID, "A finished crossing leaves no idle animation work.")
    }

    func testRepairBurstBoundsThreeHundredClicksToOneHundredSpawnsAndVisible() {
        var burst = RepairFoxBurst()
        XCTAssertEqual(RepairFoxBurst.maximumTotal, 100)
        XCTAssertEqual(RepairFoxBurst.maximumVisible, 100)
        XCTAssertEqual((0..<300).filter { _ in burst.request() }.count, 100)
        XCTAssertEqual(burst.accepted, 100)

        for index in 0..<100 {
            let time = Double(index) * 0.05
            XCTAssertTrue(burst.spawn(at: time))
        }
        XCTAssertEqual(burst.spawned, 100)
        XCTAssertEqual(burst.active, 100)
        XCTAssertNil(burst.delayUntilNext(at: 100), "A full screen must not start a 101st fox.")
        XCTAssertFalse(burst.request())
        XCTAssertNil(burst.delayUntilNext(at: 1_000))
        for _ in 0..<100 { burst.finish() }
        XCTAssertEqual(burst.active, 0)
    }

    func testRepairBurstEnforcesFortyMillisecondSpacingAndClearsPendingOnReset() {
        var burst = RepairFoxBurst()
        XCTAssertTrue(burst.request())
        XCTAssertTrue(burst.request())
        XCTAssertTrue(burst.spawn(at: 2))
        XCTAssertEqual(burst.delayUntilNext(at: 2.02) ?? -1, 0.02, accuracy: 0.0001)
        XCTAssertFalse(burst.spawn(at: 2.02))
        XCTAssertTrue(burst.spawn(at: 2.04))
        burst.reset()
        XCTAssertEqual(burst.accepted, 0)
        XCTAssertEqual(burst.active, 0)
        XCTAssertNil(burst.delayUntilNext(at: 100))
    }

    func testBundledGIFDecodesAtRetinaSizeWithItsOriginalTimingAndTransparency() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fennec-run", withExtension: "gif"))
        let asset = try FoxRunAsset.load(from: url)
        XCTAssertEqual(asset.frames.count, 14)
        XCTAssertEqual(asset.cycle.duration, 1.16, accuracy: 0.00001)
        XCTAssertEqual(asset.cycle.delays.filter { abs($0 - 0.08) < 0.00001 }.count, 10)
        XCTAssertEqual(asset.cycle.delays.filter { abs($0 - 0.09) < 0.00001 }.count, 4)
        for frame in asset.frames {
            XCTAssertEqual(frame.width, asset.frames[0].width)
            XCTAssertEqual(frame.height, asset.frames[0].height)
            XCTAssertLessThanOrEqual(frame.width, 482)
            XCTAssertGreaterThanOrEqual(frame.width, 480)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            var transparent = 0, opaque = 0, green = 0
            for pixel in stride(from: 0, to: frame.width * frame.height * 4, by: 4) {
                let r = Int(bytes[pixel]), g = Int(bytes[pixel + 1]), b = Int(bytes[pixel + 2]), a = bytes[pixel + 3]
                if a == 0 { transparent += 1 }
                if a == 255 { opaque += 1 }
                if a > 0 && g > 160 && g > r * 2 && g > b * 2 { green += 1 }
            }
            XCTAssertGreaterThan(transparent, 1000)
            XCTAssertGreaterThan(opaque, 1000)
            XCTAssertEqual(green, 0, "The GIF palette's transparent green must never become a rectangle or fringe.")
        }
    }

    @MainActor
    func testFoxPreferenceDefaultsOnAndOptOutPersists() {
        let suite = "FennecTests-fox-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.showRepairFox)
        settings.showRepairFox = false
        XCTAssertFalse(SettingsStore(defaults: defaults).showRepairFox)
    }
}
