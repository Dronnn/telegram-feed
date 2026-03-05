import Foundation
import TDLibKit

@MainActor
@Observable
final class ChannelViewModel {
    var items: [FeedItem] = []
    var isLoading = false
    var isLoadingMore = false

    let channelInfo: ChannelInfo

    init(channelInfo: ChannelInfo) {
        self.channelInfo = channelInfo
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: channelInfo.id,
                limit: 30
            )
            items = messages.map { makeItem(from: $0) }.sorted()
        } catch {}
    }

    func loadOlder() async {
        guard !isLoadingMore, let oldest = items.first else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: channelInfo.id,
                fromMessageId: oldest.messageId,
                limit: 20
            )
            let existingIDs = Set(items.map(\.id))
            let newItems = messages.map { makeItem(from: $0) }.filter { !existingIDs.contains($0.id) }
            if !newItems.isEmpty {
                items = (items + newItems).sorted()
            }
        } catch {}
    }

    private func makeItem(from message: Message) -> FeedItem {
        let formatted = extractFormattedText(from: message.content)
        let reactions = extractReactions(from: message.interactionInfo)
        let mediaInfo = message.content.extractMediaInfo()

        return FeedItem(
            chatId: message.chatId,
            messageId: message.id,
            date: message.date,
            formattedText: formatted,
            channelTitle: channelInfo.title,
            avatarFileId: channelInfo.avatarFileId,
            reactions: reactions,
            hasMedia: mediaInfo != nil,
            mediaInfo: mediaInfo
        )
    }

    private func extractFormattedText(from content: MessageContent) -> FormattedText? {
        switch content {
        case .messageText(let messageText):
            return messageText.text
        case .messagePhoto(let photo):
            return photo.caption.text.isEmpty ? nil : photo.caption
        case .messageVideo(let video):
            return video.caption.text.isEmpty ? nil : video.caption
        case .messageAnimation(let animation):
            return animation.caption.text.isEmpty ? nil : animation.caption
        case .messageVoiceNote(let voice):
            return voice.caption.text.isEmpty ? nil : voice.caption
        case .messageAudio(let audio):
            return audio.caption.text.isEmpty ? nil : audio.caption
        case .messageDocument(let doc):
            return doc.caption.text.isEmpty ? nil : doc.caption
        default:
            return nil
        }
    }

    private func extractReactions(from info: MessageInteractionInfo?) -> [FeedItem.Reaction] {
        guard let reactions = info?.reactions?.reactions else { return [] }
        return reactions.compactMap { reaction in
            switch reaction.type {
            case .reactionTypeEmoji(let emoji):
                return FeedItem.Reaction(emoji: emoji.emoji, count: reaction.totalCount)
            default:
                return nil
            }
        }
    }
}
