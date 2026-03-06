import Foundation
import SwiftUI
import TDLibKit

@MainActor
@Observable
final class ChannelViewModel {
    var items: [FeedItem] = []
    var isLoading = false
    var isLoadingOlder = false
    var isLoadingNewer = false
    var hasReachedOldest = false
    var hasReachedNewest = false
    var lastReadInboxMessageId: Int64 = 0

    let channelInfo: ChannelInfo

    static let upwardBufferSize = 60
    private static let upwardTrimThreshold = upwardBufferSize + 30
    private static let upwardLoadTriggerThreshold = 5

    private let initialWindow = 50
    private let pageSize = 30
    private var markAsReadTask: Task<Void, Never>?
    private var oldestHistoryCursor: Int64?

    init(channelInfo: ChannelInfo) {
        self.channelInfo = channelInfo
    }

    func load(aroundMessageId: Int64? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        hasReachedOldest = false
        hasReachedNewest = false

        do {
            let chat = try await TDLibService.shared.getChat(chatId: channelInfo.id)
            lastReadInboxMessageId = chat.lastReadInboxMessageId
        } catch {}

        let messages: [Message]
        if let aroundMessageId {
            let around = await fetchWindow(aroundMessageId: aroundMessageId)
            if around.isEmpty {
                messages = await fetchLatest(limit: initialWindow)
                hasReachedNewest = true
            } else {
                messages = around
            }
        } else {
            messages = await fetchLatest(limit: initialWindow)
            hasReachedNewest = true
            if messages.count < initialWindow {
                hasReachedOldest = true
            }
        }

        var mappedItems = makeItems(from: messages)
        if let aroundMessageId,
           !mappedItems.contains(where: { $0.matches(FeedItemID(chatId: channelInfo.id, messageId: aroundMessageId)) }),
           let exactMessage = await fetchExactMessage(messageId: aroundMessageId) {
            mappedItems = normalizeItems(mappedItems + makeItems(from: [exactMessage]))
        }

        performStableMutation {
            items = normalizeItems(mappedItems)
        }
        oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
    }

    func loadOlderIfNeeded(currentPosition: FeedItemID?) async -> Bool {
        guard let currentPosition,
              let itemsAbove = items.firstIndex(where: { $0.matches(currentPosition) }) else {
            return false
        }
        guard itemsAbove <= Self.upwardLoadTriggerThreshold else { return false }
        let deficit = Self.upwardBufferSize - itemsAbove
        guard deficit > 0 else { return false }
        return await loadOlderByDeficit(deficit)
    }

    func trimTopIfNeeded(currentPosition: FeedItemID?) {
        guard let currentPosition,
              let currentIndex = items.firstIndex(where: { $0.matches(currentPosition) }) else { return }
        guard currentIndex > Self.upwardTrimThreshold else { return }
        let trimCount = currentIndex - Self.upwardBufferSize
        performStableMutation {
            items.removeFirst(trimCount)
        }
        oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
        hasReachedOldest = false
    }

    private func loadOlderByDeficit(_ deficit: Int) async -> Bool {
        guard !isLoadingOlder, !hasReachedOldest,
              let startingCursor = oldestHistoryCursor ?? items.first?.representedMessageIds.min() ?? items.first?.messageId else {
            return false
        }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let fetchLimit = max(deficit, pageSize)
        var cursor = startingCursor

        for _ in 0..<6 {
            let previousCursor = cursor
            let messages = await fetchHistory(
                fromMessageId: cursor,
                limit: fetchLimit
            )

            if let fetchedOldest = messages.map(\.id).min() {
                oldestHistoryCursor = min(oldestHistoryCursor ?? .max, fetchedOldest)
                if fetchedOldest < cursor {
                    cursor = fetchedOldest
                }
            }

            if messages.isEmpty || messages.count <= 1 {
                hasReachedOldest = true
                return false
            }

            let existingMessageIDs = representedMessageIDs(in: items)
            let newItems = makeItems(
                from: messages.filter {
                    !existingMessageIDs.contains(FeedItemID(chatId: channelInfo.id, messageId: $0.id))
                }
            )

            if !newItems.isEmpty {
                insertItemsMerged(newItems)
                oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
                return true
            }

            guard cursor < previousCursor else { return false }
        }

        return false
    }

    func loadNewer() async {
        guard !isLoadingNewer, !hasReachedNewest, let newest = items.last else { return }
        isLoadingNewer = true
        defer { isLoadingNewer = false }

        let newestMessageID = newest.representedMessageIds.max() ?? newest.messageId
        let messages = await fetchHistory(
            fromMessageId: newestMessageID,
            limit: pageSize,
            offset: -(pageSize - 1)
        )

        if messages.isEmpty {
            hasReachedNewest = true
            return
        }

        let rawCount = messages.count
        let existingMessageIDs = representedMessageIDs(in: items)
        let newItems = makeItems(
            from: messages.filter {
                !existingMessageIDs.contains(FeedItemID(chatId: channelInfo.id, messageId: $0.id))
            }
        )

        if rawCount < pageSize {
            hasReachedNewest = true
        }

        guard !newItems.isEmpty else { return }

        insertItemsMerged(newItems)
    }

    func isRead(_ item: FeedItem) -> Bool {
        item.messageId <= lastReadInboxMessageId
    }

    func scheduleMarkAsRead(currentPosition: FeedItemID?) {
        markAsReadTask?.cancel()
        guard let currentPosition else { return }
        markAsReadTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await markVisibleAsRead(currentPosition: currentPosition)
        }
    }

    // MARK: - Private

    private func markVisibleAsRead(currentPosition: FeedItemID?) async {
        guard let currentPosition,
              let currentIndex = items.firstIndex(where: { $0.matches(currentPosition) }) else { return }

        var unreadIds: [Int64] = []

        for item in items.prefix(through: currentIndex) {
            let ids = item.representedMessageIds.filter { $0 > lastReadInboxMessageId }
            unreadIds.append(contentsOf: ids)
        }

        guard !unreadIds.isEmpty else { return }

        do {
            try await TDLibService.shared.viewMessages(chatId: channelInfo.id, messageIds: unreadIds)
            if let maxMarked = unreadIds.max() {
                lastReadInboxMessageId = max(lastReadInboxMessageId, maxMarked)
            }
        } catch {}
    }

    private func fetchLatest(limit: Int) async -> [Message] {
        let latest = await fetchHistory(fromMessageId: 0, limit: 1)
        guard let newest = latest.first else { return [] }
        return await fetchHistory(fromMessageId: newest.id, limit: limit)
    }

    private func fetchHistory(fromMessageId: Int64, limit: Int, offset: Int = 0) async -> [Message] {
        do {
            return try await TDLibService.shared.getChatHistory(
                chatId: channelInfo.id,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: offset
            )
        } catch {
            return []
        }
    }

    private func fetchExactMessage(messageId: Int64) async -> Message? {
        let exact = await fetchHistory(fromMessageId: messageId, limit: 1, offset: 0)
        return exact.first(where: { $0.id == messageId })
    }

    private func fetchWindow(aroundMessageId: Int64) async -> [Message] {
        let around = await fetchHistory(
            fromMessageId: aroundMessageId,
            limit: initialWindow,
            offset: -(initialWindow / 2)
        )
        if !around.isEmpty {
            return around
        }

        guard let exactMessage = await fetchExactMessage(messageId: aroundMessageId) else {
            return []
        }

        let halfWindow = max(initialWindow / 2, 1)
        let older = await fetchHistory(
            fromMessageId: exactMessage.id,
            limit: halfWindow + 1
        )
        let newer = await fetchHistory(
            fromMessageId: exactMessage.id,
            limit: halfWindow,
            offset: -(halfWindow - 1)
        )

        let combined = uniqueMessages(older + newer)
        return combined.isEmpty ? [exactMessage] : combined
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

        let existingIDs = representedMessageIDs(in: items)
        let uniqueNewItems = newItems.filter { newItem in
            let isDuplicate = newItem.representedMessageIds.allSatisfy {
                existingIDs.contains(FeedItemID(chatId: newItem.chatId, messageId: $0))
            }
            return !isDuplicate
        }

        guard !uniqueNewItems.isEmpty else { return }

        performStableMutation {
            for newItem in uniqueNewItems {
                let insertionIndex = items.firstIndex(where: { $0 > newItem }) ?? items.endIndex
                items.insert(newItem, at: insertionIndex)
            }
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
            date: min(lhs.date, rhs.date),
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

    private func representedMessageIDs(in items: [FeedItem]) -> Set<FeedItemID> {
        Set(
            items.flatMap { item in
                item.representedMessageIds.map {
                    FeedItemID(chatId: item.chatId, messageId: $0)
                }
            }
        )
    }

    private func performStableMutation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.scrollPositionUpdatePreservesVelocity = true
        transaction.scrollContentOffsetAdjustmentBehavior = .automatic
        withTransaction(transaction, updates)
    }

}
