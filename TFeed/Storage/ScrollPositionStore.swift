import Foundation

struct ScrollPositionStore: Sendable {
    private static let chatIdKey = "lastRead.chatId"
    private static let messageIdKey = "lastRead.messageId"

    static func save(_ position: FeedItemID) {
        UserDefaults.standard.set(position.chatId, forKey: chatIdKey)
        UserDefaults.standard.set(position.messageId, forKey: messageIdKey)
    }

    static func load() -> FeedItemID? {
        let chatId = UserDefaults.standard.object(forKey: chatIdKey) as? Int64
        let messageId = UserDefaults.standard.object(forKey: messageIdKey) as? Int64
        guard let chatId, let messageId else { return nil }
        return FeedItemID(chatId: chatId, messageId: messageId)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: chatIdKey)
        UserDefaults.standard.removeObject(forKey: messageIdKey)
    }
}
