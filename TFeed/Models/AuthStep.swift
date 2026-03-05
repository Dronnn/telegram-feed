import Foundation

enum AuthStep: Sendable, Equatable, Hashable {
    case phoneInput
    case codeInput
    case passwordInput
}
