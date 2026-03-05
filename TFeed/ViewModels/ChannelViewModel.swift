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
        } catch { print("[TFeed] Error: \(error)") }
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
        } catch { print("[TFeed] Error: \(error)") }
    }

    private func makeItem(from message: Message) -> FeedItem {
        let mediaInfo = message.content.extractMediaInfo()

        return FeedItem(
            chatId: message.chatId,
            messageId: message.id,
            date: message.date,
            formattedText: message.content.extractFormattedText(),
            channelTitle: channelInfo.title,
            avatarFileId: channelInfo.avatarFileId,
            reactions: message.interactionInfo?.extractReactions() ?? [],
            mediaInfo: mediaInfo
        )
    }
}
