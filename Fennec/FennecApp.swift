import SwiftUI

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
/// activation policy for a real window, which is exactly when a user has
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
            Button(model.manualFoxRequestCount > 0
                ? RepairCopy.onboardingReplayButton : "Repair Audio Now") {
                model.requestRepairButton()
            }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.manualFoxRequestCount > 0
                    ? model.manualFoxRequestCount >= RepairFoxBurst.maximumTotal
                    : model.isRepairing || model.isPreparingRepair)
            Divider()
            if model.isPaused {
                Button("Resume Watching") { model.resume() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            } else {
                Menu("Pause Repair Responses") {
                    ForEach(PauseSchedule.Option.allCases) { option in
                        Button(option.title) { model.pause(option) }
                    }
                }
            }
            Divider()
            Button("Repair History") { model.showActivityWindow() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Restart Monitor") { model.restartMonitoring() }
            Button("Reveal Event Log") { model.openEventLog() }
        }
    }

}
