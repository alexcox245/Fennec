import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app icon as a thing you can pick up.
///
/// System Settings sometimes wants the app itself rather than a button press:
/// the Open at Login list accepts an app dropped straight into it, and so
/// does the Applications folder in Finder. The polished version of that
/// moment (familiar from utilities like Clicky) hands the user the icon
/// right next to the instruction, so "find the app" never involves a Finder
/// safari through Downloads. The drag carries the real bundle URL; wherever
/// it lands, it is the same Fennec.app.
struct DraggableAppIcon: View {
    /// Grid-cell size of the icon itself.
    var iconSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
            Text("Fennec.app")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.tertiary)
        }
        .onDrag {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.applicationBundle.identifier,
                fileOptions: [],
                visibility: .all
            ) { completion in
                completion(Bundle.main.bundleURL, true, nil)
                return nil
            }
            provider.registerObject(Bundle.main.bundleURL as NSURL, visibility: .all)
            provider.suggestedName = Bundle.main.bundleURL.lastPathComponent
            return provider
        }
        .help("Drag this into a System Settings list, or into your Applications folder.")
        .accessibilityLabel("Fennec app icon. Draggable into System Settings lists or the Applications folder.")
    }

    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}
