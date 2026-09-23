import SwiftUI

/// The confirmation card, as a sheet, for the app's real windows.
///
/// The popover cannot use a sheet (or an alert) because presenting either
/// from a `MenuBarExtra(.window)` scene dismisses the panel that is showing
/// it. Windows have no such problem, so they get a sheet; both render the
/// same `PendingConfirmation`, so the two can never say different things
/// about the same decision.
struct ConfirmationSheet: View {
    let confirmation: PendingConfirmation
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(confirmation.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(confirmation.message)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = confirmation.monospacedDetail {
                Text(detail)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            HStack {
                Spacer()
                Button(confirmation.cancelTitle, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(confirmation.isDestructive ? .red : FennecBrand.sky)
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(confirmation.accessibilityDescription)
    }
}

extension View {
    /// Presents whatever question the model is currently asking.
    func fennecConfirmation(_ model: AppModel) -> some View {
        sheet(item: Binding(
            get: { model.pendingConfirmation },
            set: { newValue in
                // A sheet dismissed by any route means "no".
                if newValue == nil, let open = model.pendingConfirmation { model.cancel(open) }
            }
        )) { confirmation in
            ConfirmationSheet(
                confirmation: confirmation,
                confirm: { model.confirm(confirmation) },
                cancel: { model.cancel(confirmation) }
            )
        }
    }
}

/// The foreground choice shown for a detected fault in Ask me first mode, or
/// when automatic repair has to fall back to administrator authorization.
struct RepairPromptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let prompt = model.promptedRepair {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 13) {
                        Image("FennecMascot")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(RepairCopy.promptTitle)
                                .font(.system(size: 19, weight: .semibold, design: .default))
                                .accessibilityAddTraits(.isHeader)
                            Text(prompt.deviceName)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }

                    Text(RepairCopy.promptConsequence)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    HStack(spacing: 10) {
                        Spacer()
                        Button(RepairCopy.promptDismissTitle) {
                            model.dismissDetectedRepairPrompt(episodeID: prompt.episodeID)
                        }
                        .keyboardShortcut(.cancelAction)
                        Button(model.isRepairing || model.isPreparingRepair ? "Repairing…" : RepairCopy.promptRepairTitle) {
                            model.requestPromptedRepair(prompt)
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRepairing || model.isPreparingRepair)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 460, height: 330)
        .fennecConfirmation(model)
    }
}
