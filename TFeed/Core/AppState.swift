import Foundation

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
}
