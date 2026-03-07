import Foundation
import SwiftUI
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
    var initialAnchorID: FeedItemID?
    private(set) var lastReadInboxMessageIDs: [Int64: Int64] = [:]

    private var listeningTask: Task<Void, Never>?
    private var markAsReadTask: Task<Void, Never>?
    private(set) var lastScheduledReadPosition: FeedItemID?
    private var activeChannelIDs: Set<Int64> = []
    private var channelOldestMessageIDs: [Int64: Int64] = [:]
    private var channelsWithFullHistoryLoaded: Set<Int64> = []
    private var bufferedIncomingMessages: [Message] = []
    private var deferredOlderItems: [FeedItem] = []

    private let initialLoadLimit = 30
    private let refreshPageSize = 50
    private let historyFetchPadding = 8
    static let upwardBufferSize = 30
    private static let upwardTrimThreshold = upwardBufferSize + 15
    private static let upwardLoadTriggerThreshold = 5

    // MARK: - Public

    func load(selectedIDs: Set<Int64>) async {
        guard !isLoading else { return }
        if listeningTask == nil {
            startListening()
        }
        isLoading = true
        errorMessage = nil
        isAtBottom = false
        defer { isLoading = false }

        do {
            activeChannelIDs = selectedIDs
            try await TDLibService.shared.loadChats()
            channels = try await loadChannels()

            let activeIDs = selectedIDs.intersection(Set(channels.keys))
            activeChannelIDs = activeIDs
            channelOldestMessageIDs = [:]
            channelsWithFullHistoryLoaded = []
            deferredOlderItems = []

            guard !activeIDs.isEmpty else {
                performStableMutation {
                    items = []
                }
                unreadCount = 0
                isAtBottom = true
                bufferedIncomingMessages.removeAll()
                deferredOlderItems.removeAll()
                return
            }

            var collected: [FeedItem] = []
            await withTaskGroup(of: ChannelLoadResult.self) { group in
                for chatId in activeIDs {
                    group.addTask {
                        await self.loadInitialMessages(chatId: chatId)
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

            performStableMutation {
                items = normalizeItems(collected)
            }
            applyBufferedIncomingMessages()

            if let targetID = preferredInitialAnchorID(),
               let preparedTargetID = await prepareWindow(around: targetID, keepingPreviewCount: 10) {
                initialAnchorID = preparedTargetID
                isAtBottom = false
            }
        } catch {
            errorMessage = "Unable to load feed. Check your connection."
        }
    }

    func loadOlderIfNeeded(currentPosition: FeedItemID?) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let currentPosition,
              let itemsAbove = items.firstIndex(where: { $0.matches(currentPosition) }) else {
            return false
        }

        let anchorItem = items[itemsAbove]
        if flushDeferredOlderItems(before: anchorItem) {
            return true
        }

        guard itemsAbove <= Self.upwardLoadTriggerThreshold else {
            return false
        }

        let deficit = Self.upwardBufferSize - itemsAbove
        guard deficit > 0 else { return false }
        return await loadOlder(deficit: deficit, before: anchorItem)
    }

    private func loadOlder(deficit: Int, before anchorItem: FeedItem? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isLoadingMore, !activeChannelIDs.isEmpty else { return false }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let activeIDs = activeChannelIDs.subtracting(channelsWithFullHistoryLoaded)
        guard !activeIDs.isEmpty else { return false }

        let numChannels = max(activeIDs.count, 1)
        let perChannelLimit = max(Int(ceil(Double(deficit) / Double(numChannels))), 3)

        var olderMessagesByChannel: [Int64: [Message]] = [:]

        await withTaskGroup(of: (Int64, [Message]).self) { group in
            for chatId in activeIDs {
                guard let fromMessageId = channelOldestMessageIDs[chatId], fromMessageId != 0 else { continue }
                group.addTask {
                    guard !Task.isCancelled else { return (chatId, []) }
                    let messages = await self.fetchMessages(
                        chatId: chatId,
                        fromMessageId: fromMessageId,
                        limit: perChannelLimit
                    )
                    guard !Task.isCancelled else { return (chatId, []) }
                    return (chatId, messages)
                }
            }

            for await (chatId, messages) in group {
                olderMessagesByChannel[chatId] = messages
            }
        }

        guard !Task.isCancelled else { return false }

        let existingMessageIDs = representedMessageIDs(in: items + deferredOlderItems, chatId: nil)
        var additions: [FeedItem] = []
        var bufferedDeferredItems = false

        for (chatId, messages) in olderMessagesByChannel {
            if let oldest = messages.map(\.id).min() {
                let previous = channelOldestMessageIDs[chatId] ?? .max
                channelOldestMessageIDs[chatId] = min(previous, oldest)
            }

            if messages.isEmpty || messages.count <= 1 {
                channelsWithFullHistoryLoaded.insert(chatId)
                continue
            }

            let uniqueMessages = messages.filter {
                !existingMessageIDs.contains(FeedItemID(chatId: chatId, messageId: $0.id))
            }
            let unique = makeItems(from: uniqueMessages)

            guard !unique.isEmpty else { continue }

            if let anchorItem {
                let safeItems = unique.filter { $0 < anchorItem }
                let deferredItems = unique.filter { !($0 < anchorItem) }
                additions.append(contentsOf: safeItems)
                if !deferredItems.isEmpty {
                    bufferDeferredOlderItems(deferredItems)
                    bufferedDeferredItems = true
                }
            } else {
                additions.append(contentsOf: unique)
            }
        }

        if !additions.isEmpty {
            insertItemsMerged(additions)
            return true
        }

        return bufferedDeferredItems
    }

    func refresh(selectedIDs: Set<Int64>, currentPosition: FeedItemID? = nil) async {
        guard !isLoading else { return }
        errorMessage = nil

        let visibleSelectedIDs = selectedIDs.intersection(Set(channels.keys))
        guard !items.isEmpty, visibleSelectedIDs == activeChannelIDs else {
            await load(selectedIDs: selectedIDs)
            return
        }

        do {
            try await TDLibService.shared.loadChats()
            channels = try await loadChannels()

            let refreshedActiveIDs = selectedIDs.intersection(Set(channels.keys))
            guard refreshedActiveIDs == activeChannelIDs else {
                await load(selectedIDs: selectedIDs)
                return
            }

            await refreshNewestMessages()
            applyBufferedIncomingMessages()
            updateBottomState(isAtBottom, currentPosition: currentPosition)
        } catch {
            errorMessage = "Unable to load feed. Check your connection."
        }
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
                    lastReadInboxMessageIDs[chatId] = chat.lastReadInboxMessageId
                }
            } catch { print("[FeedViewModel] Failed to load chat \(chatId): \(error)") }
        }

        let validNewIDs = newIDs.intersection(Set(channels.keys))
        let removedIDs = activeChannelIDs.subtracting(validNewIDs)
        let addedIDs = validNewIDs.subtracting(activeChannelIDs)

        guard !removedIDs.isEmpty || !addedIDs.isEmpty else { return }

        if !removedIDs.isEmpty {
            performStableMutation {
                items.removeAll { removedIDs.contains($0.chatId) }
            }
            deferredOlderItems.removeAll { removedIDs.contains($0.chatId) }
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
                    if messages.count < initialLoadLimit + historyFetchPadding {
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
            unreadCount = isAtBottom ? 0 : unreadCount
            return
        }

        if let index = items.firstIndex(where: { $0.matches(position) }) {
            unreadCount = unreadCountBelow(index: index)
        } else if isAtBottom {
            unreadCount = 0
        }
    }

    func updateBottomState(_ newValue: Bool, currentPosition: FeedItemID?) {
        isAtBottom = newValue
        if newValue {
            unreadCount = 0
        } else {
            updateScrollPosition(currentPosition)
        }
    }

    private func unreadCountBelow(index: Int) -> Int {
        guard index < items.count - 1 else { return 0 }
        return items[(index + 1)...].count { !isRead($0) }
    }

    func trimTopIfNeeded(currentPosition: FeedItemID?) {
        guard let currentPosition,
              let currentIndex = items.firstIndex(where: { $0.matches(currentPosition) }) else { return }

        guard currentIndex > Self.upwardTrimThreshold else { return }
        trimItemsBeforeIndex(currentIndex, keepingPreviewCount: Self.upwardBufferSize)
    }

    func syncReadState(chatId: Int64, lastReadMessageId: Int64, currentPosition: FeedItemID?) {
        let current = lastReadInboxMessageIDs[chatId] ?? 0
        lastReadInboxMessageIDs[chatId] = max(current, lastReadMessageId)

        if let currentPosition, let index = items.firstIndex(where: { $0.matches(currentPosition) }) {
            unreadCount = unreadCountBelow(index: index)
        }
    }

    func isRead(_ item: FeedItem) -> Bool {
        guard let lastRead = lastReadInboxMessageIDs[item.chatId] else { return false }
        return item.messageId <= lastRead
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

    // MARK: - Private

    private func markVisibleAsRead(currentPosition: FeedItemID?) async {
        guard let currentPosition,
              let currentIndex = items.firstIndex(where: { $0.matches(currentPosition) }) else { return }

        var unreadByChat: [Int64: [Int64]] = [:]

        for item in items.prefix(through: currentIndex) {
            let lastRead = lastReadInboxMessageIDs[item.chatId] ?? 0
            let unreadIds = item.representedMessageIds.filter { $0 > lastRead }
            guard !unreadIds.isEmpty else { continue }
            unreadByChat[item.chatId, default: []].append(contentsOf: unreadIds)
        }

        for (chatId, messageIds) in unreadByChat {
            do {
                try await TDLibService.shared.viewMessages(chatId: chatId, messageIds: messageIds)
                let maxMarked = messageIds.max() ?? 0
                let current = lastReadInboxMessageIDs[chatId] ?? 0
                lastReadInboxMessageIDs[chatId] = max(current, maxMarked)
            } catch { print("markVisibleAsRead failed: \(error)") }
        }
    }

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
                lastReadInboxMessageIDs[chatId] = chat.lastReadInboxMessageId
            }
        }

        return allChannels
    }

    private func fetchLatestMessages(chatId: Int64, limit: Int) async -> [Message] {
        guard !Task.isCancelled else { return [] }
        do {
            let latest = try await TDLibService.shared.getChatHistory(chatId: chatId, limit: 1)
            guard let newest = latest.first else { return [] }
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: chatId,
                fromMessageId: newest.id,
                limit: limit + historyFetchPadding
            )
            guard !Task.isCancelled else { return [] }
            return messages
        } catch {
            return []
        }
    }

    private func fetchMessages(chatId: Int64, fromMessageId: Int64, limit: Int, offset: Int = 0) async -> [Message] {
        guard !Task.isCancelled else { return [] }
        do {
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit + historyFetchPadding,
                offset: offset
            )
            guard !Task.isCancelled else { return [] }
            return messages
        } catch {
            return []
        }
    }

    private func loadInitialMessages(
        chatId: Int64
    ) async -> ChannelLoadResult {
        let latest = await fetchLatestMessages(chatId: chatId, limit: initialLoadLimit)
        let messages = uniqueMessages(latest)
        let reachedOldest = latest.count < initialLoadLimit + historyFetchPadding

        return ChannelLoadResult(
            chatId: chatId,
            messages: messages,
            reachedOldest: reachedOldest
        )
    }

    private func applyIncomingMessage(_ message: Message, allowBuffering: Bool = true) {
        guard activeChannelIDs.contains(message.chatId) else { return }

        if allowBuffering && (isLoading || channels[message.chatId] == nil) {
            guard !bufferedIncomingMessages.contains(where: { $0.id == message.id }) else { return }
            bufferedIncomingMessages.append(message)
            return
        }

        guard let item = makeItem(from: message) else { return }
        guard !representedMessageIDs(in: items, chatId: message.chatId).contains(item.id) else {
            return
        }

        performStableMutation {
            let insertionIndex = items.firstIndex(where: { $0 > item }) ?? items.endIndex
            items.insert(item, at: insertionIndex)
        }

        if !isRead(item) {
            unreadCount += 1
        }
    }

    private func applyBufferedIncomingMessages() {
        let pending = bufferedIncomingMessages
        bufferedIncomingMessages.removeAll()
        guard !pending.isEmpty else { return }
        let sorted = pending.sorted(by: { $0.id < $1.id })
        let newItems = sorted.compactMap { makeItem(from: $0) }
        insertItemsMerged(newItems)
    }

    private func makeItem(from message: Message) -> FeedItem? {
        guard message.content.shouldAppearInFeed else { return nil }
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
        normalizeItems(messages.compactMap { makeItem(from: $0) })
    }

    private func insertItemsMerged(_ newItems: [FeedItem]) {
        guard !newItems.isEmpty else { return }

        let existingIDs = representedMessageIDs(in: items + deferredOlderItems, chatId: nil)
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

    private func bufferDeferredOlderItems(_ newItems: [FeedItem]) {
        guard !newItems.isEmpty else { return }

        let existingIDs = representedMessageIDs(in: items + deferredOlderItems, chatId: nil)
        let uniqueNewItems = newItems.filter { newItem in
            let isDuplicate = newItem.representedMessageIds.allSatisfy {
                existingIDs.contains(FeedItemID(chatId: newItem.chatId, messageId: $0))
            }
            return !isDuplicate
        }

        guard !uniqueNewItems.isEmpty else { return }
        deferredOlderItems = normalizeItems(deferredOlderItems + uniqueNewItems)
    }

    private func flushDeferredOlderItems(before anchorItem: FeedItem) -> Bool {
        guard !Task.isCancelled else { return false }
        let itemsToInsert = deferredOlderItems.filter { $0 < anchorItem }
        guard !itemsToInsert.isEmpty else { return false }

        let idsToInsert = Set(itemsToInsert.map(\.id))
        deferredOlderItems.removeAll { idsToInsert.contains($0.id) }
        insertItemsMerged(itemsToInsert)
        return true
    }

    private func preferredInitialAnchorID() -> FeedItemID? {
        if let firstUnread = items.first(where: { !isRead($0) }) {
            return firstUnread.id
        }
        return items.last?.id
    }

    private func prepareWindow(
        around targetID: FeedItemID,
        keepingPreviewCount previewCount: Int
    ) async -> FeedItemID? {
        guard !items.isEmpty else { return nil }

        if let currentIndex = items.firstIndex(where: { $0.matches(targetID) }),
           currentIndex < previewCount {
            let deficit = previewCount - currentIndex
            _ = await loadOlder(deficit: deficit)
        }

        guard let resolvedTarget = items.first(where: { $0.matches(targetID) })?.id,
              let targetIndex = items.firstIndex(where: { $0.id == resolvedTarget }) else {
            return nil
        }

        trimItemsBeforeIndex(targetIndex, keepingPreviewCount: previewCount)
        return items.first(where: { $0.matches(resolvedTarget) })?.id
    }

    private func trimItemsBeforeIndex(_ currentIndex: Int, keepingPreviewCount previewCount: Int) {
        guard currentIndex > previewCount else { return }

        let trimCount = currentIndex - previewCount
        let removedItems = Array(items.prefix(trimCount))
        performStableMutation {
            items.removeFirst(trimCount)
        }

        let affectedChatIds = Set(removedItems.map(\.chatId))
        for chatId in affectedChatIds {
            let minMessageId = items
                .filter { $0.chatId == chatId }
                .flatMap(\.representedMessageIds)
                .min()

            if let minMessageId {
                channelOldestMessageIDs[chatId] = minMessageId
            }

            channelsWithFullHistoryLoaded.remove(chatId)
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

    private func refreshNewestMessages() async {
        var additions: [FeedItem] = []
        let newestLoadedByChat = Dictionary(
            uniqueKeysWithValues: activeChannelIDs.compactMap { chatId in
                newestLoadedMessageID(for: chatId).map { (chatId, $0) }
            }
        )

        await withTaskGroup(of: [Message].self) { group in
            for chatId in activeChannelIDs {
                group.addTask {
                    if let newestLoadedMessageID = newestLoadedByChat[chatId] {
                        return await self.fetchNewerMessages(
                            chatId: chatId,
                            after: newestLoadedMessageID
                        )
                    }

                    return await self.fetchLatestMessages(
                        chatId: chatId,
                        limit: self.initialLoadLimit
                    )
                }
            }

            for await messages in group {
                additions.append(contentsOf: makeItems(from: messages))
            }
        }

        if !additions.isEmpty {
            insertItemsMerged(additions)
        }
    }

    private func newestLoadedMessageID(for chatId: Int64) -> Int64? {
        items
            .filter { $0.chatId == chatId }
            .flatMap(\.representedMessageIds)
            .max()
    }

    private func fetchNewerMessages(chatId: Int64, after messageId: Int64) async -> [Message] {
        var collected: [Message] = []
        var seen: Set<Int64> = []
        var cursor = messageId

        while true {
            let batch = await fetchMessages(
                chatId: chatId,
                fromMessageId: cursor,
                limit: refreshPageSize,
                offset: -(refreshPageSize - 1)
            )

            guard !batch.isEmpty else { break }

            let newerMessages = batch
                .filter { $0.id > messageId }
                .filter { seen.insert($0.id).inserted }

            guard !newerMessages.isEmpty else { break }

            collected.append(contentsOf: newerMessages)

            guard batch.count >= refreshPageSize + historyFetchPadding,
                  let nextCursor = newerMessages.map(\.id).max(),
                  nextCursor > cursor else {
                break
            }

            cursor = nextCursor
        }

        return uniqueMessages(collected)
    }

    private func performStableMutation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.scrollPositionUpdatePreservesVelocity = true
        transaction.scrollContentOffsetAdjustmentBehavior = .automatic
        withTransaction(transaction, updates)
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

private struct ChannelLoadResult: Sendable {
    let chatId: Int64
    let messages: [Message]
    let reachedOldest: Bool
}
