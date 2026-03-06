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
    let mediaAlbumId: Int64?
    let representedMessageIds: [Int64]
    let mediaItems: [MediaInfo]

    var id: FeedItemID { FeedItemID(chatId: chatId, messageId: messageId) }

    var mediaInfo: MediaInfo? {
        guard !mediaItems.isEmpty else { return nil }
        if mediaItems.count == 1 {
            return mediaItems[0]
        }
        return .album(mediaItems)
    }

    var postReference: PostReference {
        PostReference(
            target: id,
            label: "\(channelSlug)/\(serverMessageID)"
        )
    }

    var serverMessageID: Int64 {
        let shifted = messageId >> 20
        return shifted > 0 ? shifted : messageId
    }

    private var channelSlug: String {
        let trimmed = channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "post" }
        let lowered = trimmed.lowercased()
        let normalized = lowered
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return String(normalized.prefix(24))
    }

    var text: String {
        formattedText?.text ?? ""
    }

    func matches(_ target: FeedItemID) -> Bool {
        chatId == target.chatId && representedMessageIds.contains(target.messageId)
    }

    struct Reaction: Sendable, Hashable {
        let emoji: String
        let count: Int
    }

    struct PostReference: Sendable, Hashable {
        let target: FeedItemID
        let label: String
    }

    static func < (lhs: FeedItem, rhs: FeedItem) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.chatId != rhs.chatId { return lhs.chatId < rhs.chatId }
        return lhs.messageId < rhs.messageId
    }
}
