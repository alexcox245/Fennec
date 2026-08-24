import SwiftUI

/// Colour tokens, sampled from `Brand/Fennec-AppIcon-Master.png`.
///
/// Semantics (see AGENTS.md §7): **sky** is healthy/listening and the primary
/// action tint, **dune** is audio/warning, **sand** and **cream** are surfaces
/// and mascot framing only, **ink** is text and hardware chrome. **Gold** is
/// the aviator frames — the single warm-metal note in an otherwise flat,
/// matte palette — and is reserved for one thing: a repair that worked.
enum FennecBrand {
    static let sky = Color(red: 0.18, green: 0.51, blue: 0.80)
    static let dune = Color(red: 0.96, green: 0.47, blue: 0.12)
    static let cream = Color(red: 1.00, green: 0.89, blue: 0.67)
    static let sand = Color(red: 0.94, green: 0.72, blue: 0.43)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.11)

    /// Aviator gold, `#DA963E`. Earned, rare, never a third warning colour.
    static let gold = Color(red: 0.855, green: 0.588, blue: 0.243)

    static let card = Color.primary.opacity(0.055)
    static let cardStroke = Color.primary.opacity(0.08)
}

@main
struct FennecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .tint(FennecBrand.sky)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: model.menuBarIconState))
                .accessibilityLabel(model.menuBarIconState.accessibilityLabel)
        }
        .menuBarExtraStyle(.window)
        .commands { FennecCommands(model: model) }
    }
}

/// The main menu.
///
/// An accessory app shows no menu bar, so for most of Fennec's life none of
/// this is on screen. It appears the moment `WindowPresenter` flips the
/// activation policy for a real window — which is exactly when a user has
/// something in front of them to type ⌘W, ⌘Q, ⌘, or ⌘R at.
struct FennecCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Fennec") { WindowPresenter.shared.showAbout(model: model) }
        }

        CommandGroup(replacing: .newItem) { }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { WindowPresenter.shared.showSettings(model: model) }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("What Fennec Does") { model.showWelcomeWindow() }
            Button("About Fennec, in Detail") { WindowPresenter.shared.showAbout(model: model) }
        }

        CommandMenu("Audio") {
            Button("Repair Audio Now") { model.requestManualRepair() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRepairing)
            Divider()
            if model.isPaused {
                Button("Resume Watching") { model.resume() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            } else {
                Menu("Pause Automatic Repair") {
                    ForEach(PauseSchedule.Option.allCases) { option in
                        Button(option.title) { model.pause(option) }
                    }
                }
            }
            Divider()
            Button("Activity") { model.showActivityWindow() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Restart Monitor") { model.restartMonitoring() }
            Button("Reveal Event Log in Finder") { model.openEventLog() }
        }
    }

}
