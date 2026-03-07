import Foundation
import TDLibKit
import UIKit

#if DEBUG
private func debugLog(_ message: @autoclosure () -> String) { print(message()) }
#else
@inline(__always) private func debugLog(_ message: @autoclosure () -> String) {}
#endif

extension TDLibClient: @retroactive @unchecked Sendable {}
extension TDLibClientManager: @retroactive @unchecked Sendable {}
extension Chat: @retroactive @unchecked Sendable {}
extension Message: @retroactive @unchecked Sendable {}
extension File: @retroactive @unchecked Sendable {}
extension FormattedText: @retroactive @unchecked Sendable {}
extension TextEntity: @retroactive @unchecked Sendable {}
extension TextEntityType: @retroactive @unchecked Sendable {}
extension ResendCodeReason: @retroactive @unchecked Sendable {}
extension ResendCodeReasonVerificationFailed: @retroactive @unchecked Sendable {}

actor TDLibService {
    enum TDLibServiceError: Swift.Error {
        case clientNotInitialized
        case documentDirectoryUnavailable
        case fileDownloadTimedOut
        case fileDownloadFailed
    }

    static let shared = TDLibService()

    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    private var knownChannels: [Int64: ChannelInfo] = [:]
    let updateRouter = UpdateRouter()

    private init() {}

    func initialize() {
        if manager == nil {
            manager = TDLibClientManager()
        }
        guard client == nil, let manager else { return }

        let service = self
        let client = manager.createClient(
            updateHandler: Self.makeUpdateHandler(service: service)
        )
        self.client = client
    }

    func getClient() -> TDLibClient? {
        client
    }

    func cachedChannelInfos() -> [Int64: ChannelInfo] {
        knownChannels
    }

    func resetLocalData() async throws {
        guard let client else { throw TDLibServiceError.clientNotInitialized }
        knownChannels.removeAll()
        _ = try await client.destroy()
    }

    // MARK: - TDLib Parameters

    func setParameters() async throws {
        guard let client else { throw TDLibServiceError.clientNotInitialized }

        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { throw TDLibServiceError.documentDirectoryUnavailable }

        let databasePath = documentsURL
            .appendingPathComponent("tdlib", isDirectory: true)
            .path
        let filesPath = documentsURL
            .appendingPathComponent("tdlib_files", isDirectory: true)
            .path

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        let deviceModel = await UIDevice.current.model
        let systemVersion = await UIDevice.current.systemVersion

        try await client.setTdlibParameters(
            apiHash: Constants.apiHash,
            apiId: Constants.apiId,
            applicationVersion: appVersion,
            databaseDirectory: databasePath,
            databaseEncryptionKey: Data(),
            deviceModel: deviceModel,
            filesDirectory: filesPath,
            systemLanguageCode: langCode,
            systemVersion: systemVersion,
            useChatInfoDatabase: true,
            useFileDatabase: true,
            useMessageDatabase: true,
            useSecretChats: false,
            useTestDc: false
        )
    }

    // MARK: - Authorization

    func sendPhoneNumber(_ phoneNumber: String) async throws {
        guard let client else { throw TDLibServiceError.clientNotInitialized }
        debugLog("[TDLib Auth] Sending phone number")
        try await client.setAuthenticationPhoneNumber(
            phoneNumber: phoneNumber,
            settings: nil
        )
        debugLog("[TDLib Auth] setAuthenticationPhoneNumber succeeded")
    }

    func resendAuthenticationCode(reason: ResendCodeReason = .resendCodeReasonUserRequest) async throws {
        guard let client else { throw TDLibServiceError.clientNotInitialized }
        debugLog("[TDLib Auth] Resending authentication code, reason: \(reason)")
        _ = try await client.resendAuthenticationCode(reason: reason)
        debugLog("[TDLib Auth] resendAuthenticationCode succeeded")
    }

    func reportAuthenticationCodeMissing() async throws {
        guard let client else { throw TDLibServiceError.clientNotInitialized }
        debugLog("[TDLib Auth] Reporting authentication code missing")
        try await client.reportAuthenticationCodeMissing(mobileNetworkCode: nil)
        debugLog("[TDLib Auth] reportAuthenticationCodeMissing succeeded")
    }

    func sendCode(_ code: String) async throws {
        guard let client else { throw TDLibServiceError.clientNotInitialized }
        try await client.checkAuthenticationCode(code: code)
    }

    func sendPassword(_ password: String) async throws {
        guard let client else { throw TDLibServiceError.clientNotInitialized }
        try await client.checkAuthenticationPassword(password: password)
    }

    func logOut() async throws {
        guard let client else { return }
        try await client.logOut()
    }

    func optimizeStorage() async throws {
        guard let client else { return }
        _ = try await client.optimizeStorage(
            chatIds: [],
            chatLimit: 0,
            count: 0,
            excludeChatIds: [],
            fileTypes: nil,
            immunityDelay: 0,
            returnDeletedFileStatistics: false,
            size: 0,
            ttl: 0
        )
    }

    func cacheChannelInfo(from chat: Chat) {
        guard case .chatTypeSupergroup = chat.type else { return }
        knownChannels[chat.id] = ChannelInfo(
            id: chat.id,
            title: chat.title,
            avatarFileId: chat.photo?.small.id
        )
    }

    nonisolated private static func makeUpdateHandler(service: TDLibService) -> (Data, TDLibClient) -> Void {
        { data, client in
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                Task {
                    await service.processIncomingUpdate(update, fromClientID: client.id)
                }
            } catch {
                // Decoding failures are expected for unsupported update types
            }
        }
    }

    private func processIncomingUpdate(_ update: Update, fromClientID clientID: Int32) {
        updateRouter.send(update)
        handle(update: update, fromClientID: clientID)
    }

    private func handle(update: Update, fromClientID clientID: Int32) {
        switch update {
        case .updateAuthorizationState(let state):
            if case .authorizationStateClosed = state.authorizationState,
               client?.id == clientID {
                client = nil
                knownChannels.removeAll()
                initialize()
            }

        case .updateNewChat(let value):
            cacheChannelInfo(from: value.chat)

        case .updateChatTitle(let value):
            if let existing = knownChannels[value.chatId] {
                knownChannels[value.chatId] = ChannelInfo(
                    id: existing.id,
                    title: value.title,
                    avatarFileId: existing.avatarFileId
                )
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    _ = try? await self.getChat(chatId: value.chatId)
                }
            }

        case .updateChatPhoto(let value):
            if let existing = knownChannels[value.chatId] {
                knownChannels[value.chatId] = ChannelInfo(
                    id: value.chatId,
                    title: existing.title,
                    avatarFileId: value.photo?.small.id
                )
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    _ = try? await self.getChat(chatId: value.chatId)
                }
            }

        default:
            break
        }
    }
}
