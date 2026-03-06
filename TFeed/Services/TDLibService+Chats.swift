import Foundation
import TDLibKit

extension TDLibService {
    func loadChats(limit: Int = 100) async throws {
        guard let client = getClient() else { return }
        try await client.loadChats(chatList: nil, limit: limit)
    }

    func getChats(limit: Int = 100) async throws -> [Int64] {
        guard let client = getClient() else { return [] }
        let result = try await client.getChats(chatList: nil, limit: limit)
        return result.chatIds
    }

    func getChat(chatId: Int64) async throws -> Chat {
        guard let client = getClient() else { throw TDLibServiceError.clientNotInitialized }
        return try await client.getChat(chatId: chatId)
    }
}
