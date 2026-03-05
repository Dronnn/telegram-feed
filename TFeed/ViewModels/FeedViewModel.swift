import Foundation
import TDLibKit

@MainActor
@Observable
final class FeedViewModel {
    var items: [FeedItem] = []
    var channels: [Int64: ChannelInfo] = [:]
    var isLoading = false
    var isLoadingMore = false
    var unreadCount = 0
    var isAtBottom = true
    var errorMessage: String?

    private var listeningTask: Task<Void, Never>?

    // MARK: - Public

    func load(selectedIDs: Set<Int64>) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await TDLibService.shared.loadChats()

            let chatIds = try await TDLibService.shared.getChats()

            var allChannels: [Int64: ChannelInfo] = [:]
            for chatId in chatIds {
                let chat = try await TDLibService.shared.getChat(chatId: chatId)
                switch chat.type {
                case .chatTypeSupergroup:
                    allChannels[chatId] = ChannelInfo(
                        id: chatId,
                        title: chat.title,
                        avatarFileId: chat.photo?.small.id
                    )
                default:
                    break
                }
            }
            channels = allChannels

            let activeIDs = selectedIDs.isEmpty
                ? Set(channels.keys)
                : selectedIDs.intersection(Set(channels.keys))

            var allItems: [FeedItem] = []
            await withTaskGroup(of: [FeedItem].self) { group in
                for chatId in activeIDs {
                    group.addTask {
                        await self.fetchMessages(chatId: chatId)
                    }
                }
                for await batch in group {
                    allItems.append(contentsOf: batch)
                }
            }

            items = allItems.sorted()
        } catch {
            errorMessage = "Unable to load feed. Check your connection."
        }
    }

    func loadOlder() async {
        guard !isLoadingMore, !items.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let activeIDs = Set(items.map(\.chatId))
        var olderItems: [FeedItem] = []

        await withTaskGroup(of: [FeedItem].self) { group in
            for chatId in activeIDs {
                let oldestInChannel = items.first(where: { $0.chatId == chatId })
                let fromId = oldestInChannel?.messageId ?? 0
                group.addTask {
                    await self.fetchMessages(chatId: chatId, fromMessageId: fromId, limit: 20)
                }
            }
            for await batch in group {
                olderItems.append(contentsOf: batch)
            }
        }

        let existingIDs = Set(items.map(\.id))
        let newItems = olderItems.filter { !existingIDs.contains($0.id) }
        if !newItems.isEmpty {
            items = (items + newItems).sorted()
        }
    }

    func refresh(selectedIDs: Set<Int64>) async {
        errorMessage = nil
        await load(selectedIDs: selectedIDs)
    }

    func startListening() {
        listeningTask?.cancel()
        listeningTask = Task {
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                guard !Task.isCancelled else { break }
                if case .updateNewMessage(let newMessage) = update {
                    let message = newMessage.message
                    guard channels[message.chatId] != nil else { continue }
                    let item = makeItem(from: message)
                    if !items.contains(where: { $0.id == item.id }) {
                        items.append(item)
                        items.sort()
                        if !isAtBottom {
                            unreadCount += 1
                        }
                    }
                }
            }
        }
    }

    func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil
    }

    // MARK: - Private

    private func fetchMessages(chatId: Int64, fromMessageId: Int64 = 0, limit: Int = 30) async -> [FeedItem] {
        do {
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit
            )
            return messages.map { makeItem(from: $0) }
        } catch {
            return []
        }
    }

    func updateScrollPosition(_ position: FeedItemID?) {
        guard let position else {
            isAtBottom = true
            unreadCount = 0
            return
        }
        if let last = items.last, position == last.id {
            isAtBottom = true
            unreadCount = 0
        } else {
            isAtBottom = false
            // Update unread count based on items below current position
            if let index = items.firstIndex(where: { $0.id == position }) {
                let belowCount = items.count - index - 1
                unreadCount = max(unreadCount, belowCount)
            }
        }
    }

    func scrolledToBottom() {
        isAtBottom = true
        unreadCount = 0
    }

    private func makeItem(from message: Message) -> FeedItem {
        let channel = channels[message.chatId]
        let formatted = extractFormattedText(from: message.content)
        let reactions = extractReactions(from: message.interactionInfo)
        let mediaInfo = message.content.extractMediaInfo()

        return FeedItem(
            chatId: message.chatId,
            messageId: message.id,
            date: message.date,
            formattedText: formatted,
            channelTitle: channel?.title ?? "",
            avatarFileId: channel?.avatarFileId,
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
