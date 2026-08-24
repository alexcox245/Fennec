import SwiftUI

enum FennecBrand {
    static let sky = Color(red: 0.18, green: 0.51, blue: 0.80)
    static let dune = Color(red: 0.96, green: 0.47, blue: 0.12)
    static let cream = Color(red: 1.00, green: 0.89, blue: 0.67)
    static let sand = Color(red: 0.94, green: 0.72, blue: 0.43)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.11)

    static let card = Color.primary.opacity(0.055)
    static let cardStroke = Color.primary.opacity(0.08)
}

@main
struct FennecApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .tint(FennecBrand.sky)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Fennec")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .tint(FennecBrand.sky)
        }
    }
}
