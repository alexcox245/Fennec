import AppKit

/// What the menu-bar glyph is currently saying.
enum MenuBarIconState: String, CaseIterable, Sendable {
    /// Attached, hearing nothing wrong. The resting state, and the one the
    /// user sees 99.9% of the time.
    case listening
    /// A repair is in flight. Roughly one second, once in a while.
    case repairing
    /// The user switched Fennec off for a while.
    case paused
    /// Monitoring stopped or the listener graph failed. Needs a look.
    case attention

    /// Spoken by VoiceOver, and the tooltip when the pointer rests on the icon.
    var accessibilityLabel: String {
        switch self {
        case .listening: return "Fennec, listening"
        case .repairing: return "Fennec, restarting Core Audio"
        case .paused: return "Fennec, paused"
        case .attention: return "Fennec, needs attention"
        }
    }
}

/// The fennec, drawn small.
///
/// A menu bar is a crowded place and the stock `waveform` symbol makes Fennec
/// indistinguishable from every other audio utility on the strip — which is
/// both a branding failure and a usability one, because the user cannot find
/// their own app. This draws the one silhouette that is unmistakably this
/// product: two enormous ears over a small pointed face.
///
/// Everything here follows the icon's rules. Hard-edged vector, one confident
/// shape, cropped confidently — the ears run to the very top of the box. It is
/// a **template** image, so macOS owns the colour: it inverts correctly in a
/// dark menu bar, in light mode, when the menu is highlighted, and under
/// Increase Contrast. Nothing animates, because the desert does not animate.
@MainActor
enum MenuBarIcon {
    /// Apple's guidance for menu-bar extras. The glyph is drawn to fill it.
    static let size = NSSize(width: 18, height: 18)

    /// Design space. The path below is authored at 24×24 and scaled down, so
    /// the numbers stay readable and the shape stays resolution independent.
    private nonisolated static let designSize: CGFloat = 24

    private static var cache: [MenuBarIconState: NSImage] = [:]

    static func image(for state: MenuBarIconState) -> NSImage {
        if let cached = cache[state] { return cached }

        let image = NSImage(size: size, flipped: false) { rect in
            let scale = min(rect.width, rect.height) / designSize
            let transform = NSAffineTransform()
            transform.scaleX(by: scale, yBy: scale)
            transform.concat()

            NSColor.black.setFill()
            NSColor.black.setStroke()
            fennec().fill()

            switch state {
            case .paused:
                // Erase a wider band first so the slash still reads as a slash
                // once the menu bar inverts the template, then draw it.
                NSGraphicsContext.current?.compositingOperation = .clear
                slash(width: 5.0).stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                slash(width: 2.6).stroke()
            case .attention:
                // Carve a ring first: at 18 pt the badge sits less than a
                // point from the cheek, and without the gap they merge.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.4, dy: -1.4)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
            case .listening, .repairing:
                break
            }
            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        cache[state] = image
        return image
    }

    // MARK: The shape

    /// One continuous outline, authored in a 24×24 box with the origin at the
    /// bottom-left, traced anticlockwise from the muzzle.
    ///
    /// The read at 16 pt depends entirely on one thing: the cheek has to bulge
    /// **out** and then come back **in** to a shoulder before the ear starts.
    /// Without that pinch the ears merge into the head and the whole glyph
    /// collapses into a tulip. With it you get the silhouette everyone
    /// recognises — shoulder, ear, notch, ear, shoulder.
    ///
    /// The proportions are the point: the ears run from y≈11 to y≈23 while the
    /// head is only 10 units tall, because a fennec's ears are oversized
    /// precisely so it can hear the one signal that matters in a silent place.
    private nonisolated static func fennec() -> NSBezierPath {
        let chin = CGPoint(x: 12.0, y: 1.6)
        let cheek = CGPoint(x: 4.2, y: 8.4)
        let cheekC1 = CGPoint(x: 8.4, y: 1.7)
        let cheekC2 = CGPoint(x: 4.2, y: 4.2)
        let shoulder = CGPoint(x: 6.2, y: 11.6)
        let shoulderC1 = CGPoint(x: 4.2, y: 10.2)
        let shoulderC2 = CGPoint(x: 5.2, y: 11.4)
        let tip = CGPoint(x: 1.8, y: 22.8)
        let innerBase = CGPoint(x: 10.9, y: 13.6)
        let notch = CGPoint(x: 12.0, y: 10.2)

        func mirrored(_ point: CGPoint) -> CGPoint {
            CGPoint(x: designSize - point.x, y: point.y)
        }

        let path = NSBezierPath()
        path.move(to: chin)
        path.curve(to: cheek, controlPoint1: cheekC1, controlPoint2: cheekC2)
        path.curve(to: shoulder, controlPoint1: shoulderC1, controlPoint2: shoulderC2)
        path.line(to: tip)
        path.line(to: innerBase)
        path.line(to: notch)
        path.line(to: mirrored(innerBase))
        path.line(to: mirrored(tip))
        path.line(to: mirrored(shoulder))
        path.curve(to: mirrored(cheek), controlPoint1: mirrored(shoulderC2), controlPoint2: mirrored(shoulderC1))
        path.curve(to: chin, controlPoint1: mirrored(cheekC2), controlPoint2: mirrored(cheekC1))
        path.close()
        return path
    }

    /// The standard macOS "off" treatment: one diagonal cut through the glyph,
    /// drawn twice — once wide in `.clear` to carve a gap, once narrow in the
    /// template colour — so it stays legible against the silhouette.
    private nonisolated static func slash(width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 3.2, y: 3.4))
        path.line(to: CGPoint(x: 20.8, y: 20.6))
        path.lineWidth = width
        path.lineCapStyle = .round
        return path
    }

    /// A dot off the right cheek. Small, static, and never flashing — it says
    /// "look at me when you get a chance", not "drop everything".
    private nonisolated static let badgeRect = CGRect(x: 18.4, y: 1.0, width: 4.6, height: 4.6)
}
