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

    private var isStarted = false
    private var updateTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var firebaseResendTask: Task<Void, Never>?
    private var firebaseResendAttempts = 0
    private var codeInfo: AuthenticationCodeInfo?

    func start() {
        guard !isStarted else { return }
        isStarted = true
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
            print("[Auth] Code info - type: \(info.codeInfo.type), timeout: \(info.codeInfo.timeout)s, nextType: \(String(describing: info.codeInfo.nextType))")
            if case .authenticationCodeTypeFirebaseIos(let fbInfo) = info.codeInfo.type {
                print("[Auth] Firebase iOS code type received - pushTimeout: \(fbInfo.pushTimeout)s, length: \(fbInfo.length)")
            }
            let countdownTimeout: Int
            if case .authenticationCodeTypeFirebaseIos(let fbInfo) = info.codeInfo.type, info.codeInfo.timeout == 0 {
                countdownTimeout = Int(fbInfo.pushTimeout)
            } else {
                countdownTimeout = info.codeInfo.timeout
            }
            startResendCountdown(timeout: countdownTimeout)
            handleFirebaseAutoResend(codeType: info.codeInfo.type)

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

    func reportCodeMissingAndResend() {
        guard canResendCode else { return }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await TDLibService.shared.reportAuthenticationCodeMissing()
            } catch {
                print("[Auth] reportAuthenticationCodeMissing failed: \(error)")
            }
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
        firebaseResendTask?.cancel()
        switch step {
        case .codeInput:
            code = ""
            codeInfo = nil
            codeDeliveryDescription = nil
            canResendCode = false
            resendCountdown = 0
            firebaseResendAttempts = 0
            step = .phoneInput
        default:
            break
        }
    }

    // MARK: - Firebase Auto-Resend

    private func handleFirebaseAutoResend(codeType: AuthenticationCodeType) {
        firebaseResendTask?.cancel()
        guard case .authenticationCodeTypeFirebaseIos(let info) = codeType else { return }
        guard firebaseResendAttempts < 2 else {
            print("[Auth] Firebase auto-resend exhausted (\(firebaseResendAttempts) attempts). User must resend manually.")
            return
        }
        firebaseResendAttempts += 1

        print("[Auth] Firebase iOS detected without Firebase SDK. Will auto-resend after \(info.pushTimeout)s to trigger SMS fallback (attempt \(firebaseResendAttempts)/2).")
        let timeout = max(Int(info.pushTimeout), 3)

        firebaseResendTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            print("[Auth] Firebase push timeout elapsed, auto-resending with verification failed reason")
            do {
                let reason = ResendCodeReason.resendCodeReasonVerificationFailed(
                    ResendCodeReasonVerificationFailed(errorMessage: "APNS_RECEIVE_TIMEOUT")
                )
                try await TDLibService.shared.resendAuthenticationCode(reason: reason)
            } catch {
                print("[Auth] Firebase auto-resend failed: \(error), trying reportAuthenticationCodeMissing")
                try? await TDLibService.shared.reportAuthenticationCodeMissing()
            }
        }
    }

    // MARK: - Resend Countdown

    private func startResendCountdown(timeout: Int) {
        countdownTask?.cancel()
        let effectiveTimeout = timeout > 0 ? timeout : 30
        resendCountdown = effectiveTimeout
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
        case .authenticationCodeTypeFirebaseIos:
            return "Verifying your device... Code will be sent via SMS shortly."
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
        firebaseResendTask?.cancel()
        firebaseResendTask = nil
    }
}
