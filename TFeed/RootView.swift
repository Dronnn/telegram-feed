import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.authState {
            case .loading:
                ProgressView("Starting TDLib...")

            case .unauthorized:
                AuthView()

            case .authorized:
                FeedView()
            }
        }
        .task {
            await TDLibService.shared.initialize()
            appState.startListening()
        }
    }
}
