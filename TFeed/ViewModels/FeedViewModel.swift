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
    private var activeChannelIDs: Set<Int64> = []

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

            if selectedIDs.isEmpty {
                items = []
                activeChannelIDs = []
                return
            }

            let activeIDs = selectedIDs.intersection(Set(channels.keys))
            activeChannelIDs = activeIDs

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

        let activeIDs = activeChannelIDs
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

    func applyChannelChanges(newIDs: Set<Int64>) async {
        let unknownIDs = newIDs.subtracting(Set(channels.keys))
        for chatId in unknownIDs {
            do {
                let chat = try await TDLibService.shared.getChat(chatId: chatId)
                if case .chatTypeSupergroup = chat.type {
                    channels[chatId] = ChannelInfo(
                        id: chatId,
                        title: chat.title,
                        avatarFileId: chat.photo?.small.id
                    )
                }
            } catch {}
        }

        let validNewIDs = newIDs.intersection(Set(channels.keys))
        let removedIDs = activeChannelIDs.subtracting(validNewIDs)
        let addedIDs = validNewIDs.subtracting(activeChannelIDs)

        guard !removedIDs.isEmpty || !addedIDs.isEmpty else { return }

        var newItems: [FeedItem] = []
        if !addedIDs.isEmpty {
            await withTaskGroup(of: [FeedItem].self) { group in
                for chatId in addedIDs {
                    group.addTask {
                        await self.fetchMessages(chatId: chatId)
                    }
                }
                for await batch in group {
                    newItems.append(contentsOf: batch)
                }
            }
        }

        if !removedIDs.isEmpty {
            items.removeAll { removedIDs.contains($0.chatId) }
        }

        if !newItems.isEmpty {
            let existingIDs = Set(items.map(\.id))
            let unique = newItems.filter { !existingIDs.contains($0.id) }
            items = (items + unique).sorted()
        }

        activeChannelIDs = validNewIDs
    }

    func startListening() {
        listeningTask?.cancel()
        listeningTask = Task {
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                guard !Task.isCancelled else { break }
                if case .updateNewMessage(let newMessage) = update {
                    let message = newMessage.message
                    guard activeChannelIDs.contains(message.chatId) else { continue }
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
                unreadCount = belowCount
            }
        }
    }

    func scrolledToBottom() {
        isAtBottom = true
        unreadCount = 0
    }

    private func makeItem(from message: Message) -> FeedItem {
        let channel = channels[message.chatId]
        let mediaInfo = message.content.extractMediaInfo()

        return FeedItem(
            chatId: message.chatId,
            messageId: message.id,
            date: message.date,
            formattedText: message.content.extractFormattedText(),
            channelTitle: channel?.title ?? "",
            avatarFileId: channel?.avatarFileId,
            reactions: message.interactionInfo?.extractReactions() ?? [],
            mediaInfo: mediaInfo
        )
    }

}
