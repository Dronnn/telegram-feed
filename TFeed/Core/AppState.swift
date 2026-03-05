import Foundation
import TDLibKit

enum AuthState {
    case loading
    case unauthorized
    case authorized
}

@MainActor
@Observable
final class AppState {
    var authState: AuthState = .loading
    var selectedChannelIDs: Set<Int64> = []

    private var listenTask: Task<Void, Never>?

    func startListening() {
        listenTask?.cancel()
        listenTask = Task {
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                guard !Task.isCancelled else { break }
                if case .updateAuthorizationState(let state) = update {
                    switch state.authorizationState {
                    case .authorizationStateWaitTdlibParameters:
                        try? await TDLibService.shared.setParameters()
                    case .authorizationStateWaitPhoneNumber:
                        self.authState = .unauthorized
                    case .authorizationStateWaitCode:
                        self.authState = .unauthorized
                    case .authorizationStateWaitPassword:
                        self.authState = .unauthorized
                    case .authorizationStateReady:
                        self.authState = .authorized
                    case .authorizationStateClosed:
                        self.authState = .unauthorized
                    default:
                        break
                    }
                }
            }
        }
    }
}
