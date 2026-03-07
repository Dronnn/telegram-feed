import Foundation
import TDLibKit

extension TDLibService {
    func getMessage(chatId: Int64, messageId: Int64) async throws -> Message {
        guard let client = getClient() else { throw TDLibServiceError.clientNotInitialized }
        return try await client.getMessage(
            chatId: chatId,
            messageId: messageId
        )
    }

    func getChatHistory(
        chatId: Int64,
        fromMessageId: Int64 = 0,
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> [Message] {
        guard let client = getClient() else { return [] }
        let result = try await client.getChatHistory(
            chatId: chatId,
            fromMessageId: fromMessageId,
            limit: limit,
            offset: offset,
            onlyLocal: false
        )
        return result.messages ?? []
    }

    func viewMessages(chatId: Int64, messageIds: [Int64]) async throws {
        guard let client = getClient() else { return }
        _ = try await client.viewMessages(
            chatId: chatId,
            forceRead: true,
            messageIds: messageIds,
            source: .messageSourceChatHistory
        )
    }
}
