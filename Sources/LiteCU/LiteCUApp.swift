import SwiftUI

@main
struct LiteCUApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
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
        }
    }
}
