import Foundation
import TDLibKit

@MainActor
@Observable
final class AuthViewModel {
    var step: AuthStep = .phoneInput
    var phoneNumber: String = ""
    var code: String = ""
    var password: String = ""
    var errorMessage: String?
    var isLoading: Bool = false
    var passwordHint: String?

    private var appState: AppState?
    private var updateTask: Task<Void, Never>?

    func start(appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        updateTask = Task { [weak self] in
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                guard let self else { return }
                if case .updateAuthorizationState(let state) = update {
                    self.handleAuthState(state.authorizationState)
                }
            }
        }
    }

    private func handleAuthState(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitPhoneNumber:
            step = .phoneInput
            errorMessage = nil
            isLoading = false

        case .authorizationStateWaitCode:
            step = .codeInput
            errorMessage = nil
            isLoading = false

        case .authorizationStateWaitPassword(let info):
            step = .passwordInput
            passwordHint = info.passwordHint
            errorMessage = nil
            isLoading = false

        default:
            break
        }
    }

    // MARK: - User Actions

    func submitPhone() {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter your phone number."
            return
        }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await TDLibService.shared.sendPhoneNumber(trimmed)
            } catch {
                errorMessage = describeError(error)
            }
            isLoading = false
        }
    }

    func submitCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter the code."
            return
        }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await TDLibService.shared.sendCode(trimmed)
            } catch {
                errorMessage = describeError(error)
            }
            isLoading = false
        }
    }

    func submitPassword() {
        guard !password.isEmpty else {
            errorMessage = "Please enter your password."
            return
        }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await TDLibService.shared.sendPassword(password)
            } catch {
                errorMessage = describeError(error)
            }
            isLoading = false
        }
    }

    func goBack() {
        code = ""
        errorMessage = nil
        step = .phoneInput
    }

    // MARK: - Helpers

    private func describeError(_ error: any Swift.Error) -> String {
        if let tdError = error as? TDLibKit.Error {
            return tdError.message
        }
        return error.localizedDescription
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
    }
}
