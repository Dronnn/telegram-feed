import Foundation
import TDLibKit

struct FeedItem: Identifiable, Sendable, Comparable {
    let chatId: Int64
    let messageId: Int64
    let date: Int
    let formattedText: FormattedText?
    let channelTitle: String
    let avatarFileId: Int?
    let reactions: [Reaction]
    let hasMedia: Bool
    let mediaInfo: MediaInfo?

    var id: FeedItemID { FeedItemID(chatId: chatId, messageId: messageId) }

    var text: String {
        formattedText?.text ?? ""
    }

    struct Reaction: Sendable, Hashable {
        let emoji: String
        let count: Int
    }

    static func < (lhs: FeedItem, rhs: FeedItem) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.messageId < rhs.messageId
    }
}
