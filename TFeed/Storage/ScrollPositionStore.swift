import Foundation

enum ScrollPositionStore {
    private static let chatIdKey = "lastRead.chatId"
    private static let messageIdKey = "lastRead.messageId"
    private static let dateKey = "lastRead.date"

    static func save(_ position: FeedItemID, date: Int = 0) {
        UserDefaults.standard.set(position.chatId, forKey: chatIdKey)
        UserDefaults.standard.set(position.messageId, forKey: messageIdKey)
        if date > 0 {
            UserDefaults.standard.set(date, forKey: dateKey)
        }
    }

    static func load() -> FeedItemID? {
        let chatId = UserDefaults.standard.object(forKey: chatIdKey) as? Int64
        let messageId = UserDefaults.standard.object(forKey: messageIdKey) as? Int64
        guard let chatId, let messageId else { return nil }
        return FeedItemID(chatId: chatId, messageId: messageId)
    }

    static func loadDate() -> Int? {
        UserDefaults.standard.object(forKey: dateKey) as? Int
    }

    static func saveIfNeeded(_ position: FeedItemID?, date: Int = 0) {
        guard let position, load() != position else { return }
        save(position, date: date)
    }

}
