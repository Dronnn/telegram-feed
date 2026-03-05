import Foundation

struct FeedItemID: Hashable, Codable, Comparable, Sendable {
    let chatId: Int64
    let messageId: Int64

    static func < (lhs: FeedItemID, rhs: FeedItemID) -> Bool {
        if lhs.chatId != rhs.chatId { return lhs.chatId < rhs.chatId }
        return lhs.messageId < rhs.messageId
    }
}
