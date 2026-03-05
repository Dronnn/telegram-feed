import SwiftUI
import SwiftData

@main
struct TFeedApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
        .modelContainer(for: SelectedChannel.self)
    }
}
