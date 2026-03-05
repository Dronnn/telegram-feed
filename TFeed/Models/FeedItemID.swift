import Foundation

struct FeedItemID: Hashable, Codable, Sendable {
    let chatId: Int64
    let messageId: Int64
}
