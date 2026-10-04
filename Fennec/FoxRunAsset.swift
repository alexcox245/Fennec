import CoreGraphics
import Foundation
import ImageIO

/// Immutable decoded images may cross from the utility task to the main
/// actor. They are never drawn into or otherwise mutated after construction.
struct FoxRunAsset: @unchecked Sendable {
    let frames: [CGImage]
    let cycle: FoxRunCycle

    enum LoadError: Error { case invalidGIF }

    /// Decode once at Retina size, off the main actor. No file I/O or image
    /// decoding happens in the animation or in the repair's awaited path.
    static func load(from url: URL) throws -> FoxRunAsset {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 14 else { throw LoadError.invalidGIF }
        let imageScale = 2 * FoxRunMotion.preferredWidth / FoxRunMotion.sourceBounds.width
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: ceil(FoxRunMotion.sourceSize.width * imageScale),
            kCGImageSourceShouldCacheImmediately: true
        ]
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                  let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime]
                    ?? gif[kCGImagePropertyGIFDelayTime]) as? NSNumber,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
            else { throw LoadError.invalidGIF }

            // ImageIO composites GIF disposal into the full canvas. The
            // alpha-bounds crop is in top-left image coordinates, not AppKit
            // window coordinates. Keep fractional rounding outside the art.
            let scaleX = CGFloat(thumbnail.width) / FoxRunMotion.sourceSize.width
            let scaleY = CGFloat(thumbnail.height) / FoxRunMotion.sourceSize.height
            let bounds = FoxRunMotion.sourceBounds
            let crop = CGRect(
                x: bounds.minX * scaleX, y: bounds.minY * scaleY,
                width: bounds.width * scaleX, height: bounds.height * scaleY
            ).integral
            guard let frame = thumbnail.cropping(to: crop) else { throw LoadError.invalidGIF }
            frames.append(frame)
            delays.append(delay.doubleValue)
        }
        guard let cycle = FoxRunCycle(delays: delays) else { throw LoadError.invalidGIF }
        return FoxRunAsset(frames: frames, cycle: cycle)
    }
}
