import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.authState {
        case .loading:
            ProgressView("Starting TDLib...")

        case .unauthorized:
            AuthView()

        case .authorized:
            FeedView()
        }
    }
}
