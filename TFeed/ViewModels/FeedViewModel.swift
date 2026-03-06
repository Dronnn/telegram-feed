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
    var pendingScrollToItemID: FeedItemID?
    var initialAnchorID: FeedItemID?

    private var listeningTask: Task<Void, Never>?
    private var activeChannelIDs: Set<Int64> = []
    private var channelOldestMessageIDs: [Int64: Int64] = [:]
    private var channelsWithFullHistoryLoaded: Set<Int64> = []
    private var bufferedIncomingMessages: [Message] = []

    private let initialLoadLimit = 30
    private let restoreBackfillLimit = 100
    static let upwardBufferSize = 30

    // MARK: - Public

    func load(selectedIDs: Set<Int64>, restoredPosition: FeedItemID? = nil) async {
        guard !isLoading else { return }
        if listeningTask == nil {
            startListening()
        }
        isLoading = true
        errorMessage = nil
        pendingScrollToItemID = nil
        isAtBottom = (restoredPosition == nil)
        defer { isLoading = false }

        do {
            activeChannelIDs = selectedIDs
            try await TDLibService.shared.loadChats()
            channels = try await loadChannels()

            let activeIDs = selectedIDs.intersection(Set(channels.keys))
            activeChannelIDs = activeIDs
            channelOldestMessageIDs = [:]
            channelsWithFullHistoryLoaded = []
            let restoreContext = await loadRestoreContext(
                for: restoredPosition,
                activeIDs: activeIDs
            )

            guard !activeIDs.isEmpty else {
                items = []
                unreadCount = 0
                isAtBottom = true
                bufferedIncomingMessages.removeAll()
                return
            }

            var collected: [FeedItem] = []
            await withTaskGroup(of: ChannelLoadResult.self) { group in
                for chatId in activeIDs {
                    group.addTask {
                        await self.loadInitialMessages(
                            chatId: chatId,
                            restoreContext: restoreContext
                        )
                    }
                }

                for await result in group {
                    if let oldest = result.messages.map(\.id).min() {
                        let chatId = result.chatId
                        channelOldestMessageIDs[chatId] = oldest
                    }
                    if result.reachedOldest {
                        channelsWithFullHistoryLoaded.insert(result.chatId)
                    }
                    collected.append(contentsOf: makeItems(from: result.messages))
                }
            }

            items = normalizeItems(collected)
            applyBufferedIncomingMessages()

            if restoredPosition == nil {
                let startOfToday = Calendar.current.startOfDay(for: Date())
                let startOfTodayTimestamp = Int(startOfToday.timeIntervalSince1970)

                if let anchorIndex = items.firstIndex(where: { $0.date >= startOfTodayTimestamp }) {
                    initialAnchorID = items[anchorIndex].id
                    if anchorIndex > Self.upwardBufferSize {
                        items = Array(items[(anchorIndex - Self.upwardBufferSize)...])
                        let affectedChatIds = Set(items.map(\.chatId))
                        for chatId in affectedChatIds {
                            if let minId = items
                                .filter({ $0.chatId == chatId })
                                .flatMap(\.representedMessageIds)
                                .min() {
                                channelOldestMessageIDs[chatId] = minId
                            }
                        }
                        channelsWithFullHistoryLoaded = []
                    }
                    isAtBottom = false
                }
            }
        } catch {
            errorMessage = "Unable to load feed. Check your connection."
        }
    }

    func loadOlderIfNeeded(currentPosition: FeedItemID?) async {
        guard let currentPosition else { return }
        let itemsAbove = items.firstIndex(where: { $0.id == currentPosition }) ?? 0
        let deficit = Self.upwardBufferSize - itemsAbove
        guard deficit > 0 else { return }
        await loadOlder(deficit: deficit)
    }

    private func loadOlder(deficit: Int) async {
        guard !isLoadingMore, !activeChannelIDs.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let activeIDs = activeChannelIDs.subtracting(channelsWithFullHistoryLoaded)
        guard !activeIDs.isEmpty else { return }

        let numChannels = max(activeIDs.count, 1)
        let perChannelLimit = max(Int(ceil(Double(deficit) / Double(numChannels))), 3)

        var olderMessagesByChannel: [Int64: [Message]] = [:]

        await withTaskGroup(of: (Int64, [Message]).self) { group in
            for chatId in activeIDs {
                guard let fromMessageId = channelOldestMessageIDs[chatId], fromMessageId != 0 else { continue }
                group.addTask {
                    let messages = await self.fetchMessages(
                        chatId: chatId,
                        fromMessageId: fromMessageId,
                        limit: perChannelLimit
                    )
                    return (chatId, messages)
                }
            }

            for await (chatId, messages) in group {
                olderMessagesByChannel[chatId] = messages
            }
        }

        let existingMessageIDs = representedMessageIDs(in: items, chatId: nil)
        var additions: [FeedItem] = []

        for (chatId, messages) in olderMessagesByChannel {
            if messages.isEmpty || messages.count <= 1 {
                channelsWithFullHistoryLoaded.insert(chatId)
            }

            let uniqueMessages = messages.filter {
                !existingMessageIDs.contains(FeedItemID(chatId: chatId, messageId: $0.id))
            }
            let unique = makeItems(from: uniqueMessages)

            if unique.isEmpty {
                channelsWithFullHistoryLoaded.insert(chatId)
            } else {
                additions.append(contentsOf: unique)
                if let oldest = messages.map(\.id).min() {
                    if let current = channelOldestMessageIDs[chatId] {
                        channelOldestMessageIDs[chatId] = min(current, oldest)
                    } else {
                        channelOldestMessageIDs[chatId] = oldest
                    }
                }
            }
        }

        if !additions.isEmpty {
            insertItemsMerged(additions)
        }
    }

    func refresh(selectedIDs: Set<Int64>, restoredPosition: FeedItemID? = nil) async {
        errorMessage = nil
        await load(selectedIDs: selectedIDs, restoredPosition: restoredPosition)
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

        if !removedIDs.isEmpty {
            items.removeAll { removedIDs.contains($0.chatId) }
            for chatId in removedIDs {
                channelOldestMessageIDs.removeValue(forKey: chatId)
                channelsWithFullHistoryLoaded.remove(chatId)
            }
        }

        if !addedIDs.isEmpty {
            var added: [FeedItem] = []
            await withTaskGroup(of: (Int64, [Message]).self) { group in
                for chatId in addedIDs {
                    group.addTask {
                        let messages = await self.fetchLatestMessages(chatId: chatId, limit: self.initialLoadLimit)
                        return (chatId, messages)
                    }
                }

                for await (chatId, messages) in group {
                    if let oldest = messages.map(\.id).min() {
                        channelOldestMessageIDs[chatId] = oldest
                    }
                    if messages.count < initialLoadLimit {
                        channelsWithFullHistoryLoaded.insert(chatId)
                    }
                    added.append(contentsOf: makeItems(from: messages))
                }
            }

            if !added.isEmpty {
                insertItemsMerged(added)
            }
        }

        activeChannelIDs = validNewIDs
    }

    func startListening() {
        guard listeningTask == nil else { return }
        listeningTask = Task {
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                guard !Task.isCancelled else { break }
                guard case .updateNewMessage(let newMessage) = update else { continue }

                applyIncomingMessage(newMessage.message)
            }
        }
    }

    func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil
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
            return
        }

        isAtBottom = false
        if let index = items.firstIndex(where: { $0.id == position }) {
            let belowCount = items.count - index - 1
            unreadCount = max(0, belowCount)
        }
    }

    func trimTopIfNeeded(currentPosition: FeedItemID?) {
        guard let currentPosition,
              let currentIndex = items.firstIndex(where: { $0.id == currentPosition }) else { return }

        let excess = currentIndex - Self.upwardBufferSize
        guard excess > 0 else { return }

        let removedItems = Array(items.prefix(excess))
        items.removeFirst(excess)

        let affectedChatIds = Set(removedItems.map(\.chatId))
        for chatId in affectedChatIds {
            let minMessageId = items
                .filter { $0.chatId == chatId }
                .flatMap(\.representedMessageIds)
                .min()

            if let minMessageId {
                channelOldestMessageIDs[chatId] = minMessageId
            } else {
                channelOldestMessageIDs.removeValue(forKey: chatId)
            }
            channelsWithFullHistoryLoaded.remove(chatId)
        }
    }

    func scrolledToBottom() {
        isAtBottom = true
        unreadCount = 0
    }

    func consumePendingScrollRequest() {
        pendingScrollToItemID = nil
    }

    // MARK: - Private

    private func loadChannels() async throws -> [Int64: ChannelInfo] {
        let chatIds = try await TDLibService.shared.getChats()
        var allChannels: [Int64: ChannelInfo] = [:]

        for chatId in chatIds {
            let chat = try await TDLibService.shared.getChat(chatId: chatId)
            if case .chatTypeSupergroup = chat.type {
                allChannels[chatId] = ChannelInfo(
                    id: chatId,
                    title: chat.title,
                    avatarFileId: chat.photo?.small.id
                )
            }
        }

        return allChannels
    }

    private func fetchLatestMessages(chatId: Int64, limit: Int) async -> [Message] {
        do {
            let latest = try await TDLibService.shared.getChatHistory(chatId: chatId, limit: 1)
            guard let newest = latest.first else { return [] }
            return try await TDLibService.shared.getChatHistory(
                chatId: chatId,
                fromMessageId: newest.id,
                limit: limit
            )
        } catch {
            return []
        }
    }

    private func fetchMessages(chatId: Int64, fromMessageId: Int64, limit: Int, offset: Int = 0) async -> [Message] {
        do {
            return try await TDLibService.shared.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: offset
            )
        } catch {
            return []
        }
    }

    private func ensureRestoredMessage(_ restoredPosition: FeedItemID, in messages: [Message]) async -> [Message] {
        if messages.contains(where: { $0.id == restoredPosition.messageId }) {
            return messages
        }

        let exact = await fetchMessages(
            chatId: restoredPosition.chatId,
            fromMessageId: restoredPosition.messageId,
            limit: 1
        )
        guard let message = exact.first(where: { $0.id == restoredPosition.messageId }) else {
            return messages
        }
        return messages + [message]
    }

    private func loadRestoreContext(
        for restoredPosition: FeedItemID?,
        activeIDs: Set<Int64>
    ) async -> RestoreContext? {
        guard let restoredPosition,
              activeIDs.contains(restoredPosition.chatId),
              let message = await fetchExactMessage(
                chatId: restoredPosition.chatId,
                messageId: restoredPosition.messageId
              ) else {
            return nil
        }

        return RestoreContext(position: restoredPosition, date: message.date)
    }

    private func loadInitialMessages(
        chatId: Int64,
        restoreContext: RestoreContext?
    ) async -> ChannelLoadResult {
        guard let restoreContext else {
            let latest = await fetchLatestMessages(chatId: chatId, limit: initialLoadLimit)
            return ChannelLoadResult(
                chatId: chatId,
                messages: uniqueMessages(latest),
                reachedOldest: latest.count < initialLoadLimit
            )
        }

        var messages = uniqueMessages(
            await fetchLatestMessages(chatId: chatId, limit: initialLoadLimit)
        )
        var reachedOldest = messages.isEmpty
        var seenIDs = Set(messages.map(\.id))

        while shouldContinueRestoreBackfill(
            chatId: chatId,
            messages: messages,
            restoreContext: restoreContext,
            reachedOldest: reachedOldest
        ) {
            guard let oldestMessageId = messages.map(\.id).min() else { break }
            let olderBatch = await fetchMessages(
                chatId: chatId,
                fromMessageId: oldestMessageId,
                limit: restoreBackfillLimit
            )
            let uniqueOlder = olderBatch.filter { seenIDs.insert($0.id).inserted }

            if uniqueOlder.isEmpty {
                reachedOldest = true
                break
            }

            messages.append(contentsOf: uniqueOlder)
            if olderBatch.count <= 1 {
                reachedOldest = true
            }
        }

        if chatId == restoreContext.position.chatId {
            let restoredBatch = await ensureRestoredMessage(
                restoreContext.position,
                in: messages
            )
            messages = uniqueMessages(restoredBatch)
        }

        return ChannelLoadResult(
            chatId: chatId,
            messages: messages,
            reachedOldest: reachedOldest
        )
    }

    private func shouldContinueRestoreBackfill(
        chatId: Int64,
        messages: [Message],
        restoreContext: RestoreContext,
        reachedOldest: Bool
    ) -> Bool {
        guard !reachedOldest else { return false }

        if chatId == restoreContext.position.chatId {
            return !messages.contains(where: { $0.id == restoreContext.position.messageId })
        }

        guard let oldestDate = messages.map(\.date).min() else { return false }
        return oldestDate >= restoreContext.date
    }

    private func fetchExactMessage(chatId: Int64, messageId: Int64) async -> Message? {
        let exact = await fetchMessages(
            chatId: chatId,
            fromMessageId: messageId,
            limit: 1
        )
        return exact.first(where: { $0.id == messageId })
    }

    private func applyIncomingMessage(_ message: Message, allowBuffering: Bool = true) {
        guard activeChannelIDs.contains(message.chatId) else { return }

        if allowBuffering && (isLoading || channels[message.chatId] == nil) {
            guard !bufferedIncomingMessages.contains(where: { $0.id == message.id }) else { return }
            bufferedIncomingMessages.append(message)
            return
        }

        let item = makeItem(from: message)
        guard !representedMessageIDs(in: items, chatId: message.chatId).contains(item.id) else {
            return
        }

        let existingDisplayTarget = items.first(where: { $0.matches(item.id) })?.id

        if let albumId = item.mediaAlbumId,
           let existingIndex = items.lastIndex(where: { $0.chatId == item.chatId && $0.mediaAlbumId == albumId }) {
            items[existingIndex] = mergeAlbumItems(items[existingIndex], item)
        } else {
            items.append(item)
        }

        let displayTarget = items.first(where: { $0.matches(item.id) })?.id ?? item.id
        let insertedNewCard = existingDisplayTarget == nil

        if isAtBottom {
            unreadCount = 0
            if insertedNewCard {
                pendingScrollToItemID = displayTarget
            }
        } else if insertedNewCard {
            unreadCount += 1
        }
    }

    private func applyBufferedIncomingMessages() {
        let pending = bufferedIncomingMessages
        bufferedIncomingMessages.removeAll()
        guard !pending.isEmpty else { return }
        let sorted = pending.sorted(by: { $0.id < $1.id })
        let newItems = sorted.map { makeItem(from: $0) }
        insertItemsMerged(newItems)
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
            mediaAlbumId: normalizedAlbumID(for: message),
            representedMessageIds: [message.id],
            mediaItems: mediaInfo.map { [$0] } ?? []
        )
    }

    private func makeItems(from messages: [Message]) -> [FeedItem] {
        normalizeItems(messages.map { makeItem(from: $0) })
    }

    private func insertItemsMerged(_ newItems: [FeedItem]) {
        guard !newItems.isEmpty else { return }

        let existingIDs = representedMessageIDs(in: items, chatId: nil)

        for newItem in newItems {
            let isDuplicate = newItem.representedMessageIds.allSatisfy {
                existingIDs.contains(FeedItemID(chatId: newItem.chatId, messageId: $0))
            }
            guard !isDuplicate else { continue }

            if let albumId = newItem.mediaAlbumId,
               let existingIndex = items.lastIndex(where: { $0.chatId == newItem.chatId && $0.mediaAlbumId == albumId }) {
                items[existingIndex] = mergeAlbumItems(items[existingIndex], newItem)
                continue
            }

            let insertionIndex = items.firstIndex(where: { $0 > newItem }) ?? items.endIndex
            items.insert(newItem, at: insertionIndex)
        }
    }

    private func normalizeItems(_ items: [FeedItem]) -> [FeedItem] {
        let sorted = items.sorted()
        var normalized: [FeedItem] = []
        var seenMessageIDs: Set<FeedItemID> = []

        for item in sorted {
            let unseenRepresentedIDs = item.representedMessageIds.filter {
                seenMessageIDs.insert(FeedItemID(chatId: item.chatId, messageId: $0)).inserted
            }

            guard !unseenRepresentedIDs.isEmpty else { continue }

            let candidate = unseenRepresentedIDs.count == item.representedMessageIds.count
                ? item
                : FeedItem(
                    chatId: item.chatId,
                    messageId: item.messageId,
                    date: item.date,
                    formattedText: item.formattedText,
                    channelTitle: item.channelTitle,
                    avatarFileId: item.avatarFileId,
                    reactions: item.reactions,
                    mediaAlbumId: item.mediaAlbumId,
                    representedMessageIds: unseenRepresentedIDs,
                    mediaItems: item.mediaItems
                )

            if let last = normalized.last, canMergeAlbum(last, candidate) {
                normalized[normalized.count - 1] = mergeAlbumItems(last, candidate)
            } else {
                normalized.append(candidate)
            }
        }

        return normalized
    }

    private func uniqueMessages(_ messages: [Message]) -> [Message] {
        var seen: Set<Int64> = []
        return messages.filter { seen.insert($0.id).inserted }
    }

    private func canMergeAlbum(_ lhs: FeedItem, _ rhs: FeedItem) -> Bool {
        guard let lhsAlbumID = lhs.mediaAlbumId,
              let rhsAlbumID = rhs.mediaAlbumId else {
            return false
        }
        return lhs.chatId == rhs.chatId && lhsAlbumID == rhsAlbumID
    }

    private func mergeAlbumItems(_ lhs: FeedItem, _ rhs: FeedItem) -> FeedItem {
        let formattedText = lhs.formattedText ?? rhs.formattedText
        let reactions = lhs.reactions.isEmpty ? rhs.reactions : lhs.reactions
        let representedMessageIds = Array(
            Set(lhs.representedMessageIds + rhs.representedMessageIds)
        ).sorted()
        let mediaItems = (lhs.mediaItems + rhs.mediaItems).reduce(into: [MediaInfo]()) { partialResult, item in
            guard !partialResult.contains(item) else { return }
            partialResult.append(item)
        }

        return FeedItem(
            chatId: lhs.chatId,
            messageId: lhs.messageId,
            date: max(lhs.date, rhs.date),
            formattedText: formattedText,
            channelTitle: lhs.channelTitle,
            avatarFileId: lhs.avatarFileId,
            reactions: reactions,
            mediaAlbumId: lhs.mediaAlbumId,
            representedMessageIds: representedMessageIds,
            mediaItems: mediaItems
        )
    }

    private func normalizedAlbumID(for message: Message) -> Int64? {
        let albumID = message.mediaAlbumId.rawValue
        return albumID == 0 ? nil : albumID
    }

    private func representedMessageIDs(in items: [FeedItem], chatId: Int64?) -> Set<FeedItemID> {
        Set(
            items
                .filter { chatId == nil || $0.chatId == chatId }
                .flatMap { item in
                    item.representedMessageIds.map {
                        FeedItemID(chatId: item.chatId, messageId: $0)
                    }
                }
        )
    }
}

private struct RestoreContext: Sendable {
    let position: FeedItemID
    let date: Int
}

private struct ChannelLoadResult: Sendable {
    let chatId: Int64
    let messages: [Message]
    let reachedOldest: Bool
}
