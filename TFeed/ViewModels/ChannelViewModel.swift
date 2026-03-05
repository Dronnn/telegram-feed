import Foundation
import TDLibKit

@MainActor
@Observable
final class ChannelViewModel {
    var items: [FeedItem] = []
    var isLoading = false
    var isLoadingOlder = false
    var isLoadingNewer = false
    var hasReachedNewest = false

    let channelInfo: ChannelInfo

    init(channelInfo: ChannelInfo) {
        self.channelInfo = channelInfo
    }

    func load(aroundMessageId: Int64? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let messages: [Message]
            if let aroundMessageId {
                messages = try await TDLibService.shared.getChatHistory(
                    chatId: channelInfo.id,
                    fromMessageId: aroundMessageId,
                    limit: 30,
                    offset: -15
                )
            } else {
                messages = try await TDLibService.shared.getChatHistory(
                    chatId: channelInfo.id,
                    limit: 30
                )
                hasReachedNewest = true
            }
            items = messages.map { makeItem(from: $0) }.sorted()
        } catch { print("[TFeed] Error: \(error)") }
    }

    func loadOlder() async {
        guard !isLoadingOlder, let oldest = items.first else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

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

    func loadNewer() async {
        guard !isLoadingNewer, let newest = items.last else { return }
        isLoadingNewer = true
        defer { isLoadingNewer = false }

        do {
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: channelInfo.id,
                fromMessageId: newest.messageId,
                limit: 20,
                offset: -20
            )
            let existingIDs = Set(items.map(\.id))
            let newItems = messages.map { makeItem(from: $0) }.filter { !existingIDs.contains($0.id) }
            if newItems.isEmpty {
                hasReachedNewest = true
            } else {
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
