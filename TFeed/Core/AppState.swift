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

    func startListening() {
        Task {
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                if case .updateAuthorizationState(let state) = update {
                    switch state.authorizationState {
                    case .authorizationStateWaitTdlibParameters:
                        try? await TDLibService.shared.setParameters()
                    case .authorizationStateWaitPhoneNumber:
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
