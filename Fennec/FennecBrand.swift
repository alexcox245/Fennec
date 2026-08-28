import SwiftUI

/// Colour tokens, sampled from `Brand/Fennec-AppIcon-Master.png`.
///
/// Semantics (see AGENTS.md §7): **sky** is healthy/listening and the primary
/// action tint, **dune** is audio/warning, **sand** and **cream** are surfaces
/// and mascot framing only, **ink** is text and hardware chrome. **Gold** is
/// the aviator frames (the single warm-metal note in an otherwise flat,
/// matte palette) and is reserved for one thing: a repair that worked.
enum FennecBrand {
    static let sky = Color(red: 0.18, green: 0.51, blue: 0.80)
    static let dune = Color(red: 0.96, green: 0.47, blue: 0.12)
    static let cream = Color(red: 1.00, green: 0.89, blue: 0.67)
    static let sand = Color(red: 0.94, green: 0.72, blue: 0.43)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.11)

    /// Aviator gold, `#DA963E`. Earned, rare, never a third warning colour.
    static let gold = Color(red: 0.855, green: 0.588, blue: 0.243)

    /// Accent for a repair outcome. Gold is spent only on `.held`.
    static func accent(for outcome: RepairOutcome) -> Color {
        switch outcome {
        case .held: return gold
        case .pending: return .secondary
        case .returned: return dune
        case .failed: return .red
        }
    }

    static let card = Color.primary.opacity(0.055)
    static let cardStroke = Color.primary.opacity(0.08)
}
