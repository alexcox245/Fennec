import AppKit
import SwiftUI

/// The look and the feel of the one button in this app that restarts the
/// audio system.
///
/// Not `.borderedProminent`: the system style owns its corner radius, its
/// height, and its press behaviour, and all three are the brief here.
///
/// The button is drawn as a physical key sitting above the surface. At rest
/// it carries a drop shadow offset downward and a bright top edge, so it
/// reads as raised rather than printed. Pressing it travels the whole
/// control down by exactly the resting shadow offset and collapses the
/// shadow to almost nothing, which is what a key bottoming out looks like:
/// the gap under it closes. Because `offset` does not participate in
/// layout, nothing around the button moves.
///
/// A haptic tap fires on press-down, not on release, matching the moment
/// the shadow closes. `NSHapticFeedbackManager` is a no-op on hardware
/// without a Force Touch trackpad and already honours the system's own
/// haptic-feedback setting, so there is nothing to gate here and no setting
/// of Fennec's own to add.
///
/// Reduce Motion removes the travel animation but keeps the state change,
/// so the button still visibly responds without sliding.
struct PrimaryRepairButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A disabled button is drawn faded, which is right while a repair is
    /// running and wrong for the result flash that follows it. The
    /// confirmation is disabled so a click cannot start a second restart,
    /// but "Audio repaired" is something the user should be able to read at
    /// full strength for the two seconds it is up.
    var readsAtFullStrengthWhileDisabled = false

    /// Whether to draw this button as live, which is not the same question
    /// as whether it can be clicked.
    private var isLit: Bool { isEnabled || readsAtFullStrengthWhileDisabled }

    /// Twice the 28 pt height of the `.large` bordered button this replaces.
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 10

    /// The resting gap under the key, and therefore also how far it travels.
    /// One number for both is what makes the press read as bottoming out.
    private static let depth: CGFloat = 3

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        // A disabled button is not "held down"; it is simply flat and out of
        // service, so it must never take the pressed treatment.
        let pressed = configuration.isPressed && isEnabled

        return configuration.label
            .foregroundStyle(Color.white.opacity(isLit ? 1 : 0.55))
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .background {
                shape
                    .fill(fill(pressed: pressed))
                    .shadow(
                        color: .black.opacity(shadowOpacity(pressed: pressed)),
                        radius: pressed ? 1.5 : 5,
                        x: 0,
                        y: pressed ? 1 : Self.depth
                    )
            }
            .overlay {
                // The lit top edge of a raised key, dimmed once it is down.
                shape.strokeBorder(
                    Color.white.opacity(isLit ? (pressed ? 0.05 : 0.18) : 0.05),
                    lineWidth: 1
                )
            }
            .offset(y: pressed ? Self.depth : 0)
            .contentShape(shape)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: pressed)
            .onChange(of: configuration.isPressed) { _, nowPressed in
                guard nowPressed, isEnabled else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
    }

    private func fill(pressed: Bool) -> Color {
        guard isLit else { return FennecBrand.sky.opacity(0.32) }
        return pressed ? FennecBrand.sky.opacity(0.78) : FennecBrand.sky
    }

    private func shadowOpacity(pressed: Bool) -> Double {
        guard isLit else { return 0.08 }
        return pressed ? 0.14 : 0.34
    }
}
