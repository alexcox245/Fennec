import SwiftUI

/// The confirmation card, as a sheet, for the app's real windows.
///
/// The popover cannot use a sheet — or an alert — because presenting either
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
