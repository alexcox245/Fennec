import SwiftUI

/// One outstanding setup step, with the button that resolves it.
///
/// Shared by the popover's compact card and the Settings form so the two can
/// never offer different words for the same action; the popover used to say
/// "Enable" while Settings said "Enable Helper" for the same `SMAppService`
/// call, and only one of them knew that macOS had already staged it.
struct SetupStepRow: View {
    let step: SetupStep
    let compact: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(compact ? .caption : .body)
                .foregroundStyle(tint)
                .padding(.top, compact ? 1 : 0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(compact ? .caption.weight(.semibold) : .body.weight(.medium))
                Text(compact ? step.compactDetail : step.detail)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if step.isComplete {
                // Completed steps are stated, not offered. A button that does
                // nothing is worse than no button.
                Label(step.actionTitle, systemImage: "checkmark.circle.fill")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(FennecBrand.sky)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(step.actionTitle, action: action)
                    .controlSize(compact ? .small : .regular)
                    .buttonStyle(.bordered)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(step.title). \(step.detail)")
        .help(step.detail)
    }

    private var symbol: String {
        if step.isComplete { return "checkmark.circle.fill" }
        return step.isRequired ? "exclamationmark.circle.fill" : "circle.dashed"
    }

    private var tint: Color {
        if step.isComplete { return FennecBrand.sky }
        return step.isRequired ? FennecBrand.dune : .secondary
    }
}
