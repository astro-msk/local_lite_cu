import SwiftUI

@main
struct LiteCUApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.light.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .defaultSize(width: 1280, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { theme in
                        Text(theme.rawValue).tag(theme.rawValue)
                    }
                }
            }
        }
    }
}
