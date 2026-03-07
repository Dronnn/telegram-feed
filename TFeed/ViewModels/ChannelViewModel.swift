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
    private let albumBoundaryFetchSize = 12

    private let initialWindow = 50
    private let pageSize = 30
    private(set) var lastScheduledReadPosition: FeedItemID?
    private var markAsReadTask: Task<Void, Never>?
    private var listeningTask: Task<Void, Never>?
    private var oldestHistoryCursor: Int64?

    init(channelInfo: ChannelInfo) {
        self.channelInfo = channelInfo
    }

    func load(aroundMessageId: Int64? = nil) async -> FeedItemID? {
        guard !isLoading else { return nil }
        if listeningTask == nil {
            startListening()
        }
        isLoading = true
        defer { isLoading = false }

        hasReachedOldest = false
        hasReachedNewest = false

        do {
            let chat = try await TDLibService.shared.getChat(chatId: channelInfo.id)
            lastReadInboxMessageId = chat.lastReadInboxMessageId
        } catch { print("ChannelViewModel: failed to load chat info: \(error)") }

        let messages: [Message]
        if let aroundMessageId {
            if let exactMessage = await fetchExactMessage(messageId: aroundMessageId) {
                messages = await fetchWindow(around: exactMessage)
            } else {
                messages = await fetchLatest(limit: initialWindow)
                hasReachedNewest = true
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

        guard let aroundMessageId else {
            return items.last?.id
        }

        return await ensureTargetLoaded(messageId: aroundMessageId)
    }

    func loadOlderIfNeeded(currentPosition: FeedItemID?) async -> Bool {
        guard !Task.isCancelled else { return false }
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
        guard !Task.isCancelled else { return false }
        guard !isLoadingOlder, !hasReachedOldest,
              let startingCursor = oldestHistoryCursor ?? items.first?.representedMessageIds.min() ?? items.first?.messageId else {
            return false
        }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let fetchLimit = max(deficit, pageSize)

        let messages = await fetchHistory(
            fromMessageId: startingCursor,
            limit: fetchLimit
        )

        guard !Task.isCancelled else { return false }

        if let fetchedOldest = messages.map(\.id).min() {
            oldestHistoryCursor = min(oldestHistoryCursor ?? .max, fetchedOldest)
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

        guard !newItems.isEmpty else {
            return
        }

        insertItemsMerged(newItems)
    }

    func isRead(_ item: FeedItem) -> Bool {
        item.messageId <= lastReadInboxMessageId
    }

    func scheduleMarkAsRead(currentPosition: FeedItemID?) {
        markAsReadTask?.cancel()
        guard let currentPosition else {
            lastScheduledReadPosition = nil
            return
        }
        lastScheduledReadPosition = currentPosition
        markAsReadTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await markVisibleAsRead(currentPosition: currentPosition)
            if lastScheduledReadPosition == currentPosition {
                lastScheduledReadPosition = nil
            }
        }
    }

    func flushPendingReadState() async {
        markAsReadTask?.cancel()
        guard let position = lastScheduledReadPosition else { return }
        lastScheduledReadPosition = nil
        await markVisibleAsRead(currentPosition: position)
    }

    func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil
    }

    // MARK: - Private

    private func startListening() {
        guard listeningTask == nil else { return }
        listeningTask = Task {
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                guard !Task.isCancelled else { break }
                await handle(update: update)
            }
        }
    }

    private func handle(update: Update) async {
        switch update {
        case .updateNewMessage(let value):
            guard value.message.chatId == channelInfo.id else { break }
            if let item = makeItem(from: value.message) {
                insertItemsMerged([item])
                oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
            }

        case .updateMessageContent(let value):
            guard value.chatId == channelInfo.id else { break }
            await reconcileMessage(messageId: value.messageId)

        case .updateMessageEdited(let value):
            guard value.chatId == channelInfo.id else { break }
            await reconcileMessage(messageId: value.messageId)

        case .updateDeleteMessages(let value):
            guard value.chatId == channelInfo.id else { break }
            let removedMessageIDs = Set(value.messageIds)
            let albumRebuildAnchors = affectedAlbumRebuildAnchors(removing: removedMessageIDs)
            removeMessages(removedMessageIDs)
            await restoreAffectedAlbums(survivingMessageIds: albumRebuildAnchors)

        case .updateChatReadInbox(let value):
            guard value.chatId == channelInfo.id else { break }
            lastReadInboxMessageId = max(lastReadInboxMessageId, value.lastReadInboxMessageId)

        default:
            break
        }
    }

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
        } catch { print("markVisibleAsRead failed: \(error)") }
    }

    private func fetchLatest(limit: Int) async -> [Message] {
        let latest = await fetchHistory(fromMessageId: 0, limit: 1)
        guard let newest = latest.first else { return [] }
        return await fetchHistory(fromMessageId: newest.id, limit: limit)
    }

    private func fetchHistory(fromMessageId: Int64, limit: Int, offset: Int = 0) async -> [Message] {
        guard !Task.isCancelled else { return [] }
        do {
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: channelInfo.id,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: offset
            )
            guard !Task.isCancelled else { return [] }
            return messages
        } catch {
            return []
        }
    }

    private func fetchExactMessage(messageId: Int64) async -> Message? {
        do {
            return try await TDLibService.shared.getMessage(
                chatId: channelInfo.id,
                messageId: messageId
            )
        } catch {
            return nil
        }
    }

    private func fetchWindow(around exactMessage: Message) async -> [Message] {
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

        let combined = uniqueMessages(older + [exactMessage] + newer)
        return combined.isEmpty ? [exactMessage] : combined
    }

    private func fetchExpandedWindow(around exactMessage: Message, windowSize: Int) async -> [Message] {
        let halfWindow = max(windowSize / 2, 1)
        let older = await fetchHistory(
            fromMessageId: exactMessage.id,
            limit: halfWindow + 1
        )
        let newer = await fetchHistory(
            fromMessageId: exactMessage.id,
            limit: halfWindow,
            offset: -(halfWindow - 1)
        )

        return uniqueMessages(older + [exactMessage] + newer)
    }

    private func ensureTargetLoaded(messageId: Int64) async -> FeedItemID? {
        if let resolved = resolvedItemID(for: messageId) {
            return resolved
        }

        guard let exactMessage = await fetchExactMessage(messageId: messageId) else {
            return nil
        }

        if let exactItem = makeItem(from: exactMessage) {
            insertItemsMerged([exactItem])
            oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
        }

        if let resolved = resolvedItemID(for: messageId) {
            return resolved
        }

        var windowSize = initialWindow * 2
        while windowSize <= 400, !Task.isCancelled {
            let surrounding = await fetchExpandedWindow(around: exactMessage, windowSize: windowSize)
            let existingMessageIDs = representedMessageIDs(in: items)
            let additions = makeItems(
                from: surrounding.filter {
                    !existingMessageIDs.contains(FeedItemID(chatId: channelInfo.id, messageId: $0.id))
                }
            )

            if !additions.isEmpty {
                insertItemsMerged(additions)
                oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
            }

            if let resolved = resolvedItemID(for: messageId) {
                return resolved
            }

            if surrounding.count < windowSize {
                break
            }

            windowSize *= 2
        }

        return resolvedItemID(for: messageId)
    }

    private func reconcileMessage(messageId: Int64) async {
        removeMessages([messageId])

        guard let message = await fetchExactMessage(messageId: messageId) else {
            oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
            return
        }

        let replacements = await replacementItems(for: message)
        if !replacements.isEmpty {
            insertItemsMerged(replacements)
        }
        oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
    }

    private func replacementItems(for message: Message) async -> [FeedItem] {
        guard let albumID = normalizedAlbumID(for: message) else {
            return makeItems(from: [message])
        }

        let surrounding = await fetchHistory(
            fromMessageId: message.id,
            limit: max(pageSize, 12),
            offset: -5
        )

        let albumMessages = uniqueMessages(surrounding + [message]).filter {
            normalizedAlbumID(for: $0) == albumID
        }

        let expandedAlbum = await expandAlbumEdges(albumMessages)
        return makeItems(from: expandedAlbum)
    }

    private func removeMessages(_ messageIds: Set<Int64>) {
        guard !messageIds.isEmpty else { return }

        performStableMutation {
            items = items.compactMap { item in
                let remainingIds = item.representedMessageIds.filter { !messageIds.contains($0) }
                guard remainingIds.count != item.representedMessageIds.count else { return item }
                guard !remainingIds.isEmpty else { return nil }
                guard item.mediaAlbumId == nil else { return nil }

                return copy(
                    item,
                    messageId: remainingIds.max() ?? item.messageId,
                    representedMessageIds: remainingIds
                )
            }
        }
    }

    private func affectedAlbumRebuildAnchors(removing messageIds: Set<Int64>) -> [Int64] {
        guard !messageIds.isEmpty else { return [] }

        return Array(
            Set(
                items.compactMap { item in
                    guard item.mediaAlbumId != nil,
                          item.representedMessageIds.contains(where: { messageIds.contains($0) }) else {
                        return nil
                    }

                    return item.representedMessageIds
                        .filter { !messageIds.contains($0) }
                        .max()
                }
            )
        )
    }

    private func restoreAffectedAlbums(survivingMessageIds: [Int64]) async {
        guard !survivingMessageIds.isEmpty else { return }

        for messageId in survivingMessageIds.sorted() {
            guard let message = await fetchExactMessage(messageId: messageId) else { continue }
            let replacements = await replacementItems(for: message)
            guard !replacements.isEmpty else { continue }
            insertItemsMerged(replacements)
        }

        oldestHistoryCursor = items.first?.representedMessageIds.min() ?? items.first?.messageId
    }

    private func makeItem(from message: Message) -> FeedItem? {
        guard message.content.shouldAppearInFeed else { return nil }
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

    private func copy(
        _ item: FeedItem,
        messageId: Int64? = nil,
        representedMessageIds: [Int64]? = nil
    ) -> FeedItem {
        FeedItem(
            chatId: item.chatId,
            messageId: messageId ?? item.messageId,
            date: item.date,
            formattedText: item.formattedText,
            channelTitle: item.channelTitle,
            avatarFileId: item.avatarFileId,
            reactions: item.reactions,
            mediaAlbumId: item.mediaAlbumId,
            representedMessageIds: representedMessageIds ?? item.representedMessageIds,
            mediaItems: item.mediaItems
        )
    }

    private func makeItems(from messages: [Message]) -> [FeedItem] {
        normalizeItems(messages.compactMap { makeItem(from: $0) })
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
                if let mergedItem = mergeIntoExistingAlbumIfNeeded(newItem) {
                    insertSorted(mergedItem)
                } else {
                    insertSorted(newItem)
                }
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
                    messageId: unseenRepresentedIDs.max() ?? item.messageId,
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
        var seen: Set<FeedItemID> = []
        return messages.filter { seen.insert(messageKey(for: $0)).inserted }
    }

    private func messageKey(for message: Message) -> FeedItemID {
        FeedItemID(chatId: message.chatId, messageId: message.id)
    }

    private func expandAlbumEdges(_ messages: [Message]) async -> [Message] {
        let unique = uniqueMessages(messages)
        guard !unique.isEmpty else { return [] }

        let sorted = unique.sorted { $0.id < $1.id }
        var expanded = unique

        if let oldest = sorted.first {
            expanded.append(contentsOf: await fetchAlbumBoundarySiblings(
                boundary: oldest,
                direction: .older
            ))
        }

        if let newest = sorted.last {
            expanded.append(contentsOf: await fetchAlbumBoundarySiblings(
                boundary: newest,
                direction: .newer
            ))
        }

        return uniqueMessages(expanded)
    }

    private func fetchAlbumBoundarySiblings(
        boundary: Message,
        direction: AlbumBoundaryDirection
    ) async -> [Message] {
        guard let albumID = normalizedAlbumID(for: boundary) else { return [] }

        var cursor = boundary.id
        var collected: [Message] = []

        while !Task.isCancelled {
            let batch: [Message]
            switch direction {
            case .older:
                batch = await fetchHistory(
                    fromMessageId: cursor,
                    limit: albumBoundaryFetchSize
                )
            case .newer:
                batch = await fetchHistory(
                    fromMessageId: cursor,
                    limit: albumBoundaryFetchSize,
                    offset: -(albumBoundaryFetchSize - 1)
                )
            }

            guard !batch.isEmpty else { break }

            let candidates = batch
                .filter {
                    switch direction {
                    case .older:
                        return $0.id < cursor
                    case .newer:
                        return $0.id > cursor
                    }
                }
                .sorted { lhs, rhs in
                    switch direction {
                    case .older:
                        return lhs.id > rhs.id
                    case .newer:
                        return lhs.id < rhs.id
                    }
                }

            guard !candidates.isEmpty else { break }

            var advanced = false
            for message in candidates {
                if normalizedAlbumID(for: message) == albumID {
                    collected.append(message)
                    cursor = message.id
                    advanced = true
                } else {
                    return collected
                }
            }

            if !advanced || candidates.count < albumBoundaryFetchSize - 1 {
                break
            }
        }

        return collected
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
            messageId: representedMessageIds.max() ?? lhs.messageId,
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

    private func mergeIntoExistingAlbumIfNeeded(_ item: FeedItem) -> FeedItem? {
        guard let albumID = item.mediaAlbumId,
              let existingIndex = items.lastIndex(where: {
                  $0.chatId == item.chatId && $0.mediaAlbumId == albumID
              }) else {
            return nil
        }

        let existingItem = items.remove(at: existingIndex)
        return mergeAlbumItems(existingItem, item)
    }

    private func insertSorted(_ item: FeedItem) {
        let insertionIndex = items.firstIndex(where: { $0 > item }) ?? items.endIndex
        items.insert(item, at: insertionIndex)
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

    private func resolvedItemID(for messageId: Int64) -> FeedItemID? {
        items.first(where: { $0.matches(FeedItemID(chatId: channelInfo.id, messageId: messageId)) })?.id
    }

    private func performStableMutation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.scrollPositionUpdatePreservesVelocity = true
        transaction.scrollContentOffsetAdjustmentBehavior = .automatic
        withTransaction(transaction, updates)
    }

}

private enum AlbumBoundaryDirection {
    case older
    case newer
}
