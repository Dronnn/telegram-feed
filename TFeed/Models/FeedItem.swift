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

    static func makeItems(from messages: [Message], channelTitle: String, avatarFileId: Int?) -> [FeedItem] {
        let ordered = messages.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }

        var items: [FeedItem] = []
        var pendingAlbum: [Message] = []

        func flushAlbum() {
            guard !pendingAlbum.isEmpty else { return }
            items.append(makeItem(from: pendingAlbum, channelTitle: channelTitle, avatarFileId: avatarFileId))
            pendingAlbum.removeAll(keepingCapacity: true)
        }

        for message in ordered {
            let groupsIntoAlbum = message.mediaAlbumId != 0 && message.content.extractMediaInfo() != nil

            guard groupsIntoAlbum else {
                flushAlbum()
                items.append(makeItem(from: [message], channelTitle: channelTitle, avatarFileId: avatarFileId))
                continue
            }

            if let albumId = pendingAlbum.first?.mediaAlbumId, albumId == message.mediaAlbumId {
                pendingAlbum.append(message)
            } else {
                flushAlbum()
                pendingAlbum = [message]
            }
        }

        flushAlbum()
        return items
    }

    func merged(with other: FeedItem) -> FeedItem {
        guard chatId == other.chatId else { return self }
        guard mediaAlbumId != nil, mediaAlbumId == other.mediaAlbumId else { return self }

        let mergedMessageIds = uniqueSorted(representedMessageIds + other.representedMessageIds)
        let mergedMediaItems = uniqueMediaItems(mediaItems + other.mediaItems)
        let mergedReactions = reactions.isEmpty ? other.reactions : reactions
        let mergedText = formattedText?.text.isEmpty == false ? formattedText : other.formattedText

        return FeedItem(
            chatId: chatId,
            messageId: max(messageId, other.messageId),
            date: max(date, other.date),
            formattedText: mergedText,
            channelTitle: channelTitle.isEmpty ? other.channelTitle : channelTitle,
            avatarFileId: avatarFileId ?? other.avatarFileId,
            reactions: mergedReactions,
            mediaAlbumId: mediaAlbumId,
            representedMessageIds: mergedMessageIds,
            mediaItems: mergedMediaItems
        )
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
        return lhs.messageId < rhs.messageId
    }

    private func uniqueSorted(_ values: [Int64]) -> [Int64] {
        var seen: Set<Int64> = []
        return values
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    private func uniqueMediaItems(_ items: [MediaInfo]) -> [MediaInfo] {
        var seen: [MediaInfo] = []
        for item in items where !seen.contains(item) {
            seen.append(item)
        }
        return seen
    }

    private static func makeItem(from messages: [Message], channelTitle: String, avatarFileId: Int?) -> FeedItem {
        let ordered = messages.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }

        let primary = ordered.first(where: { message in
            guard let text = message.content.extractFormattedText()?.text else { return false }
            return !text.isEmpty
        }) ?? ordered.last!

        return FeedItem(
            chatId: primary.chatId,
            messageId: primary.id,
            date: ordered.last?.date ?? primary.date,
            formattedText: primary.content.extractFormattedText(),
            channelTitle: channelTitle,
            avatarFileId: avatarFileId,
            reactions: combinedReactions(from: ordered),
            mediaAlbumId: primary.mediaAlbumId == 0 ? nil : primary.mediaAlbumId,
            representedMessageIds: ordered.map(\.id),
            mediaItems: ordered.compactMap { $0.content.extractMediaInfo() }
        )
    }

    private static func combinedReactions(from messages: [Message]) -> [Reaction] {
        var counts: [String: Int] = [:]

        for message in messages {
            for reaction in message.interactionInfo?.extractReactions() ?? [] {
                counts[reaction.emoji] = max(counts[reaction.emoji] ?? 0, reaction.count)
            }
        }

        return counts
            .map { Reaction(emoji: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.emoji < rhs.emoji
            }
    }
}
