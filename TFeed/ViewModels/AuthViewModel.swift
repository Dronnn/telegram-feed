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

    var codeDeliveryDescription: String?
    var canResendCode: Bool = false
    var resendCountdown: Int = 0

    private var appState: AppState?
    private var updateTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var codeInfo: AuthenticationCodeInfo?

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
            codeInfo = nil
            codeDeliveryDescription = nil

        case .authorizationStateWaitCode(let info):
            codeInfo = info.codeInfo
            step = .codeInput
            errorMessage = nil
            isLoading = false
            codeDeliveryDescription = describeCodeType(info.codeInfo.type)
            print("[Auth] Code info - type: \(info.codeInfo.type), phone: \(info.codeInfo.phoneNumber), timeout: \(info.codeInfo.timeout)s, nextType: \(String(describing: info.codeInfo.nextType))")
            startResendCountdown(timeout: info.codeInfo.timeout)

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
                print("[Auth] sendPhoneNumber failed: \(error)")
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
                print("[Auth] sendCode failed: \(error)")
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
                print("[Auth] sendPassword failed: \(error)")
            }
            isLoading = false
        }
    }

    func resendCode() {
        guard canResendCode, codeInfo?.nextType != nil else { return }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await TDLibService.shared.resendAuthenticationCode()
            } catch {
                errorMessage = describeError(error)
                print("[Auth] resendAuthenticationCode failed: \(error)")
            }
            isLoading = false
        }
    }

    func goBack() {
        errorMessage = nil
        countdownTask?.cancel()
        switch step {
        case .codeInput:
            code = ""
            codeInfo = nil
            codeDeliveryDescription = nil
            canResendCode = false
            resendCountdown = 0
            step = .phoneInput
        default:
            break
        }
    }

    // MARK: - Resend Countdown

    private func startResendCountdown(timeout: Int) {
        countdownTask?.cancel()
        guard timeout > 0, codeInfo?.nextType != nil else {
            canResendCode = false
            resendCountdown = 0
            return
        }
        resendCountdown = timeout
        canResendCode = false
        countdownTask = Task { [weak self] in
            while let self, self.resendCountdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.resendCountdown -= 1
            }
            guard let self, !Task.isCancelled else { return }
            self.canResendCode = true
        }
    }

    // MARK: - Helpers

    private func describeCodeType(_ type: AuthenticationCodeType) -> String {
        switch type {
        case .authenticationCodeTypeTelegramMessage:
            return "Code sent via Telegram message to your other device."
        case .authenticationCodeTypeSms:
            return "Code sent via SMS."
        case .authenticationCodeTypeSmsWord:
            return "A word was sent via SMS."
        case .authenticationCodeTypeSmsPhrase:
            return "A phrase was sent via SMS."
        case .authenticationCodeTypeCall:
            return "You will receive a phone call with the code."
        case .authenticationCodeTypeFlashCall:
            return "You will receive a flash call. The code is the caller's number."
        case .authenticationCodeTypeMissedCall(let info):
            return "You will receive a missed call from +\(info.phoneNumberPrefix)... Enter the last \(info.length) digits."
        case .authenticationCodeTypeFragment:
            return "Code sent to Fragment (fragment.com)."
        case .authenticationCodeTypeFirebaseAndroid:
            return "Code delivery requires Firebase (Android). Please try resending."
        case .authenticationCodeTypeFirebaseIos(let info):
            print("[Auth] Firebase iOS code type received - receipt: \(info.receipt.prefix(10))..., pushTimeout: \(info.pushTimeout)s")
            return "Waiting for code verification... If nothing happens, try resending in \(info.pushTimeout)s."
        }
    }

    private func describeError(_ error: any Swift.Error) -> String {
        if let tdError = error as? TDLibKit.Error {
            return tdError.message
        }
        return error.localizedDescription
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        countdownTask?.cancel()
        countdownTask = nil
    }
}
