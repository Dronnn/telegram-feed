import Foundation
import TDLibKit

extension TDLibService {
    func loadChats(limit: Int = 200) async throws {
        guard let client = getClient() else { return }

        while true {
            do {
                _ = try await client.loadChats(chatList: nil, limit: limit)
            } catch let error as TDLibKit.Error where error.code == 404 {
                break
            }
        }
    }

    func getChats(limit: Int = 10_000) async throws -> [Int64] {
        guard let client = getClient() else { return [] }
        let result = try await client.getChats(chatList: nil, limit: limit)
        return result.chatIds
    }

    private func getAllChats() async throws -> [Int64] {
        var limit = 200
        var previousCount = -1

        while true {
            let chatIds = try await getChats(limit: limit)
            if chatIds.count == previousCount || chatIds.count < limit {
                return chatIds
            }

            previousCount = chatIds.count
            limit *= 2
        }
    }

    func getChat(chatId: Int64) async throws -> Chat {
        guard let client = getClient() else { throw TDLibServiceError.clientNotInitialized }
        let chat = try await client.getChat(chatId: chatId)
        cacheChannelInfo(from: chat)
        return chat
    }

    func loadAvailableChannels() async throws -> [Int64: ChannelInfo] {
        try await loadChats()

        let chatIds = try await getAllChats()
        for chatId in chatIds {
            _ = try await getChat(chatId: chatId)
        }

        return cachedChannelInfos()
    }
}
