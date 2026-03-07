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
    private var earliestVisibleDate: Int?
    private var currentDayFloor: Int?
    private var pendingMetadataRefreshChatIDs: Set<Int64> = []

    private let initialLoadLimit = 30
    private let refreshPageSize = 50
    private let historyFetchPadding = 8
    private let albumBoundaryFetchSize = 12
    static let upwardPreviewCount = 10
    private static let upwardLoadBatchSize = 10
    private static let upwardTrimThreshold = upwardPreviewCount + upwardLoadBatchSize
    private static let upwardLoadTriggerThreshold = upwardPreviewCount

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
            let dayStart = Self.startOfCurrentDayTimestamp()
            currentDayFloor = dayStart
            earliestVisibleDate = dayStart
            activeChannelIDs = selectedIDs
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
                currentDayFloor = nil
                earliestVisibleDate = nil
                unreadCount = 0
                isAtBottom = true
                bufferedIncomingMessages.removeAll()
                deferredOlderItems.removeAll()
                return
            }

            var collected: [FeedItem] = []
            var hiddenOlderPreviewItems: [FeedItem] = []
            var hasTodayHistory = false
            await withTaskGroup(of: ChannelLoadResult.self) { group in
                for chatId in activeIDs {
                    group.addTask {
                        await self.loadMessagesForCurrentDay(chatId: chatId, dayStart: dayStart)
                    }
                }

                for await result in group {
                    hasTodayHistory = hasTodayHistory || !result.messages.isEmpty
                    if let historyCursorMessageId = result.historyCursorMessageId {
                        channelOldestMessageIDs[result.chatId] = historyCursorMessageId
                    }
                    if result.reachedOldest {
                        channelsWithFullHistoryLoaded.insert(result.chatId)
                    }
                    hiddenOlderPreviewItems.append(contentsOf: makeItems(from: result.hiddenOlderPreviewMessages))
                    collected.append(contentsOf: makeItems(from: result.messages))
                }
            }

            performStableMutation {
                items = normalizeItems(collected)
            }
            if hasTodayHistory {
                bufferDeferredOlderItems(hiddenOlderPreviewItems)
            }
            await ensureLatestVisibleItems(chatIds: activeIDs, dayStart: dayStart)
            await supplementWithRecentMessagesIfNeeded(
                chatIds: activeIDs,
                allowFallback: !hasTodayHistory
            )
            rebuildHistoryCursors(for: activeIDs)
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

        guard itemsAbove < Self.upwardLoadTriggerThreshold else {
            return false
        }

        let anchorItem = items[itemsAbove]
        return await loadOlder(batchSize: Self.upwardLoadBatchSize, before: anchorItem)
    }

    private func loadOlder(batchSize: Int, before anchorItem: FeedItem? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isLoadingMore, !activeChannelIDs.isEmpty else { return false }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let activeIDs = activeChannelIDs.subtracting(channelsWithFullHistoryLoaded)
        guard !activeIDs.isEmpty else { return false }

        let numChannels = max(activeIDs.count, 1)
        let perChannelLimit = max(Int(ceil(Double(batchSize) / Double(numChannels))), 1)

        var olderMessagesByChannel: [Int64: [Message]] = [:]
        var channelsReachingHistoryEnd: Set<Int64> = []

        await withTaskGroup(of: (Int64, [Message], Bool).self) { group in
            for chatId in activeIDs {
                guard let fromMessageId = channelOldestMessageIDs[chatId], fromMessageId != 0 else { continue }
                group.addTask {
                    guard !Task.isCancelled else { return (chatId, [], false) }
                    let rawBatch = await self.fetchHistoryBatch(
                        chatId: chatId,
                        fromMessageId: fromMessageId,
                        limit: perChannelLimit + self.historyFetchPadding
                    )
                    let messages = await self.expandAlbumEdges(chatId: chatId, messages: rawBatch)
                    guard !Task.isCancelled else { return (chatId, [], false) }
                    return (
                        chatId,
                        messages,
                        rawBatch.count < perChannelLimit + self.historyFetchPadding
                    )
                }
            }

            for await (chatId, messages, reachedHistoryEnd) in group {
                olderMessagesByChannel[chatId] = messages
                if reachedHistoryEnd {
                    channelsReachingHistoryEnd.insert(chatId)
                }
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

            if messages.isEmpty {
                if channelsReachingHistoryEnd.contains(chatId) {
                    channelsWithFullHistoryLoaded.insert(chatId)
                }
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

            if channelsReachingHistoryEnd.contains(chatId) {
                channelsWithFullHistoryLoaded.insert(chatId)
            }
        }

        let deferredCandidates = drainDeferredOlderItems(before: anchorItem)
        let sortedAdditions = normalizeItems(additions + deferredCandidates).sorted()
        let visibleAdditions: [FeedItem]
        if sortedAdditions.count > Self.upwardLoadBatchSize {
            let deferredBatch = Array(sortedAdditions.dropLast(Self.upwardLoadBatchSize))
            bufferDeferredOlderItems(deferredBatch)
            bufferedDeferredItems = true
            visibleAdditions = Array(sortedAdditions.suffix(Self.upwardLoadBatchSize))
        } else {
            visibleAdditions = sortedAdditions
        }

        if !visibleAdditions.isEmpty {
            extendVisibleHistoryLowerBound(with: visibleAdditions)
            insertItemsMerged(visibleAdditions)
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

    func reloadCurrentDay(selectedIDs: Set<Int64>) async {
        guard !isLoading else { return }
        if listeningTask == nil {
            startListening()
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            channels = try await loadChannels()

            let activeIDs = selectedIDs.intersection(Set(channels.keys))
            let dayStart = Self.startOfCurrentDayTimestamp()
            currentDayFloor = dayStart
            earliestVisibleDate = dayStart
            activeChannelIDs = activeIDs
            channelOldestMessageIDs = [:]
            channelsWithFullHistoryLoaded = []
            deferredOlderItems = []
            bufferedIncomingMessages.removeAll()

            guard !activeIDs.isEmpty else {
                performStableMutation {
                    items = []
                }
                currentDayFloor = nil
                earliestVisibleDate = nil
                unreadCount = 0
                isAtBottom = true
                bufferedIncomingMessages.removeAll()
                return
            }

            var collected: [FeedItem] = []
            var hiddenOlderPreviewItems: [FeedItem] = []
            var hasTodayHistory = false

            await withTaskGroup(of: ChannelLoadResult.self) { group in
                for chatId in activeIDs {
                    group.addTask {
                        await self.loadMessagesForCurrentDay(chatId: chatId, dayStart: dayStart)
                    }
                }

                for await result in group {
                    hasTodayHistory = hasTodayHistory || !result.messages.isEmpty
                    if let historyCursorMessageId = result.historyCursorMessageId {
                        channelOldestMessageIDs[result.chatId] = historyCursorMessageId
                    }
                    if result.reachedOldest {
                        channelsWithFullHistoryLoaded.insert(result.chatId)
                    }
                    hiddenOlderPreviewItems.append(contentsOf: makeItems(from: result.hiddenOlderPreviewMessages))
                    collected.append(contentsOf: makeItems(from: result.messages))
                }
            }

            performStableMutation {
                items = normalizeItems(collected)
            }
            if hasTodayHistory {
                bufferDeferredOlderItems(hiddenOlderPreviewItems)
            }
            await ensureLatestVisibleItems(chatIds: activeIDs, dayStart: dayStart)
            await supplementWithRecentMessagesIfNeeded(
                chatIds: activeIDs,
                allowFallback: !hasTodayHistory
            )
            rebuildHistoryCursors(for: activeIDs)
            applyBufferedIncomingMessages()
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

        // Flip the active set immediately so live updates for newly selected
        // channels are not dropped while the initial fetch is still running.
        activeChannelIDs = validNewIDs

        if !removedIDs.isEmpty {
            performStableMutation {
                items.removeAll { removedIDs.contains($0.chatId) }
            }
            deferredOlderItems.removeAll { removedIDs.contains($0.chatId) }
            for chatId in removedIDs {
                channelOldestMessageIDs.removeValue(forKey: chatId)
                channelsWithFullHistoryLoaded.remove(chatId)
            }
            recalculateVisibleHistoryLowerBound()
        }

        if !addedIDs.isEmpty {
            var added: [FeedItem] = []
            var hiddenOlderPreviewItems: [FeedItem] = []
            let earliestVisibleDate = self.earliestVisibleDate
            await withTaskGroup(of: ChannelLoadResult.self) { group in
                for chatId in addedIDs {
                    group.addTask {
                        if let earliestVisibleDate {
                            return await self.loadMessagesForCurrentDay(
                                chatId: chatId,
                                dayStart: earliestVisibleDate
                            )
                        }

                        let messages = await self.fetchLatestMessages(
                            chatId: chatId,
                            limit: self.initialLoadLimit
                        )
                        return ChannelLoadResult(
                            chatId: chatId,
                            messages: messages,
                            reachedOldest: messages.count < self.initialLoadLimit + self.historyFetchPadding,
                            historyCursorMessageId: messages.map(\.id).min(),
                            hiddenOlderPreviewMessages: []
                        )
                    }
                }

                for await result in group {
                    if let historyCursorMessageId = result.historyCursorMessageId {
                        channelOldestMessageIDs[result.chatId] = historyCursorMessageId
                    }
                    if result.reachedOldest {
                        channelsWithFullHistoryLoaded.insert(result.chatId)
                    }
                    hiddenOlderPreviewItems.append(contentsOf: makeItems(from: result.hiddenOlderPreviewMessages))
                    added.append(contentsOf: makeItems(from: result.messages))
                }
            }

            if !added.isEmpty {
                insertItemsMerged(added)
            }
            if items.isEmpty && added.isEmpty {
                insertItemsMerged(hiddenOlderPreviewItems)
            } else {
                bufferDeferredOlderItems(hiddenOlderPreviewItems)
            }
        }
    }

    func startListening() {
        guard listeningTask == nil else { return }
        listeningTask = Task {
            let router = TDLibService.shared.updateRouter
            for await update in router.updates() {
                guard !Task.isCancelled else { break }
                await handle(update: update)
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
        trimItemsBeforeIndex(currentIndex, keepingPreviewCount: Self.upwardPreviewCount)
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
        let allChannels = try await TDLibService.shared.loadAvailableChannels()

        for chatId in allChannels.keys {
            let chat = try await TDLibService.shared.getChat(chatId: chatId)
            lastReadInboxMessageIDs[chatId] = chat.lastReadInboxMessageId
        }

        return allChannels
    }

    private func handle(update: Update) async {
        switch update {
        case .updateNewMessage(let newMessage):
            applyIncomingMessage(newMessage.message)

        case .updateMessageContent(let value):
            await reconcileMessage(chatId: value.chatId, messageId: value.messageId)

        case .updateMessageEdited(let value):
            await reconcileMessage(chatId: value.chatId, messageId: value.messageId)

        case .updateDeleteMessages(let value):
            let removedMessageIDs = Set(value.messageIds)
            let albumRebuildAnchors = affectedAlbumRebuildAnchors(
                for: value.chatId,
                removing: removedMessageIDs
            )
            removeMessages(chatId: value.chatId, messageIds: removedMessageIDs)
            await restoreAffectedAlbums(
                chatId: value.chatId,
                survivingMessageIds: albumRebuildAnchors
            )

        case .updateChatReadInbox(let value):
            syncReadState(
                chatId: value.chatId,
                lastReadMessageId: value.lastReadInboxMessageId,
                currentPosition: lastScheduledReadPosition
            )

        case .updateNewChat(let value):
            guard case .chatTypeSupergroup = value.chat.type else { break }
            handleChatMetadataChange(
                ChannelInfo(
                    id: value.chat.id,
                    title: value.chat.title,
                    avatarFileId: value.chat.photo?.small.id
                )
            )

        case .updateChatTitle(let value):
            if let current = channels[value.chatId] {
                handleChatMetadataChange(
                    ChannelInfo(
                        id: current.id,
                        title: value.title,
                        avatarFileId: current.avatarFileId
                    )
                )
            } else {
                scheduleChannelMetadataRefresh(chatId: value.chatId)
            }

        case .updateChatPhoto(let value):
            if let current = channels[value.chatId] {
                handleChatMetadataChange(
                    ChannelInfo(
                        id: value.chatId,
                        title: current.title,
                        avatarFileId: value.photo?.small.id
                    )
                )
            } else {
                scheduleChannelMetadataRefresh(chatId: value.chatId)
            }

        default:
            break
        }
    }

    private func fetchLatestMessages(chatId: Int64, limit: Int) async -> [Message] {
        guard !Task.isCancelled else { return [] }
        let latest = await fetchHistoryBatch(chatId: chatId, fromMessageId: 0, limit: 1)
        guard let newest = latest.first else { return [] }
        let messages = await fetchHistoryBatch(
            chatId: chatId,
            fromMessageId: newest.id,
            limit: limit + historyFetchPadding
        )
        return await expandAlbumEdges(chatId: chatId, messages: messages)
    }

    private func fetchMessages(chatId: Int64, fromMessageId: Int64, limit: Int, offset: Int = 0) async -> [Message] {
        let messages = await fetchHistoryBatch(
            chatId: chatId,
            fromMessageId: fromMessageId,
            limit: limit + historyFetchPadding,
            offset: offset
        )
        return await expandAlbumEdges(chatId: chatId, messages: messages)
    }

    private func fetchHistoryBatch(chatId: Int64, fromMessageId: Int64, limit: Int, offset: Int = 0) async -> [Message] {
        guard !Task.isCancelled else { return [] }
        do {
            let messages = try await TDLibService.shared.getChatHistory(
                chatId: chatId,
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

    private func expandAlbumEdges(chatId: Int64, messages: [Message]) async -> [Message] {
        let unique = uniqueMessages(messages)
        guard !unique.isEmpty else { return [] }

        let sorted = unique.sorted { $0.id < $1.id }
        var expanded = unique

        if let oldest = sorted.first {
            expanded.append(contentsOf: await fetchAlbumBoundarySiblings(
                chatId: chatId,
                boundary: oldest,
                direction: .older
            ))
        }

        if let newest = sorted.last {
            expanded.append(contentsOf: await fetchAlbumBoundarySiblings(
                chatId: chatId,
                boundary: newest,
                direction: .newer
            ))
        }

        return uniqueMessages(expanded)
    }

    private func fetchAlbumBoundarySiblings(
        chatId: Int64,
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
                batch = await fetchHistoryBatch(
                    chatId: chatId,
                    fromMessageId: cursor,
                    limit: albumBoundaryFetchSize
                )
            case .newer:
                batch = await fetchHistoryBatch(
                    chatId: chatId,
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

    private func loadInitialMessages(
        chatId: Int64
    ) async -> ChannelLoadResult {
        let latest = await fetchLatestMessages(chatId: chatId, limit: initialLoadLimit)
        let messages = uniqueMessages(latest)
        let reachedOldest = latest.count < initialLoadLimit + historyFetchPadding

        return ChannelLoadResult(
            chatId: chatId,
            messages: messages,
            reachedOldest: reachedOldest,
            historyCursorMessageId: messages.map(\.id).min(),
            hiddenOlderPreviewMessages: []
        )
    }

    private func loadMessagesForCurrentDay(chatId: Int64, dayStart: Int) async -> ChannelLoadResult {
        let initialLimit = max(initialLoadLimit, refreshPageSize)
        var messages = uniqueMessages(await fetchLatestMessages(chatId: chatId, limit: initialLimit))
        var seenIDs = Set(messages.map(messageKey(for:)))
        var reachedBoundary = messages.isEmpty
        var reachedHistoryEnd = messages.count < initialLimit + historyFetchPadding

        while !reachedBoundary, !reachedHistoryEnd, !Task.isCancelled {
            guard let oldestMessageID = messages.map(\.id).min(),
                  let oldestDate = messages.map(\.date).min() else {
                break
            }

            if oldestDate < dayStart {
                reachedBoundary = true
                break
            }

            let olderBatch = await fetchMessages(
                chatId: chatId,
                fromMessageId: oldestMessageID,
                limit: refreshPageSize
            )
            let uniqueOlder = olderBatch.filter { seenIDs.insert(messageKey(for: $0)).inserted }

            if uniqueOlder.isEmpty {
                reachedHistoryEnd = true
                break
            }

            messages.append(contentsOf: uniqueOlder)

            if uniqueOlder.contains(where: { $0.date < dayStart }) {
                reachedBoundary = true
            }

            if olderBatch.count < refreshPageSize + historyFetchPadding {
                reachedHistoryEnd = true
            }
        }

        let dayMessages = uniqueMessages(messages)
            .filter { $0.date >= dayStart }

        let ensuredMessages = await ensureLatestDayTailIncluded(
            in: dayMessages,
            chatId: chatId,
            dayStart: dayStart
        )

        let hiddenOlderPreviewMessages: [Message]
        let historyCursorMessageId: Int64?
        if ensuredMessages.isEmpty {
            let visibleOlderMessages = uniqueMessages(messages)
                .filter { $0.date < dayStart && $0.content.shouldAppearInFeed }
                .sorted {
                    if $0.date != $1.date { return $0.date < $1.date }
                    return $0.id < $1.id
                }
            hiddenOlderPreviewMessages = Array(visibleOlderMessages.suffix(Self.upwardLoadBatchSize))
            historyCursorMessageId = hiddenOlderPreviewMessages.map(\.id).min()
                ?? uniqueMessages(messages).map(\.id).min()
        } else {
            hiddenOlderPreviewMessages = []
            historyCursorMessageId = ensuredMessages.map(\.id).min()
        }

        return ChannelLoadResult(
            chatId: chatId,
            messages: ensuredMessages,
            reachedOldest: reachedHistoryEnd,
            historyCursorMessageId: historyCursorMessageId,
            hiddenOlderPreviewMessages: hiddenOlderPreviewMessages
        )
    }

    private func ensureLatestDayTailIncluded(
        in messages: [Message],
        chatId: Int64,
        dayStart: Int
    ) async -> [Message] {
        let recentTail = await fetchLatestMessages(chatId: chatId, limit: refreshPageSize)
        let latestDayMessages = recentTail.filter { $0.date >= dayStart }

        guard !latestDayMessages.isEmpty else {
            return messages
        }

        let merged = uniqueMessages(messages + latestDayMessages)
        return merged.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.id < rhs.id
        }
    }

    private func ensureLatestVisibleItems(chatIds: Set<Int64>, dayStart: Int) async {
        for chatId in chatIds {
            let latest = await fetchHistoryBatch(chatId: chatId, fromMessageId: 0, limit: 1)
            guard let newest = latest.first,
                  newest.date >= dayStart,
                  newest.content.shouldAppearInFeed,
                  !items.contains(where: {
                      $0.matches(FeedItemID(chatId: chatId, messageId: newest.id))
                  }),
                  let latestItem = makeItem(from: newest) else {
                continue
            }

            insertItemsMerged([latestItem])
        }
    }

    private func supplementWithRecentMessagesIfNeeded(chatIds: Set<Int64>, allowFallback: Bool) async {
        guard allowFallback, items.isEmpty else { return }

        var collected: [FeedItem] = []
        await withTaskGroup(of: [Message].self) { group in
            for chatId in chatIds {
                group.addTask {
                    await self.fetchLatestMessages(
                        chatId: chatId,
                        limit: Self.upwardLoadBatchSize
                    )
                }
            }

            for await messages in group {
                collected.append(contentsOf: makeItems(from: messages))
            }
        }

        guard !collected.isEmpty else { return }

        performStableMutation {
            items = normalizeItems(items + collected)
        }
    }

    private func rebuildHistoryCursors(for chatIds: Set<Int64>) {
        for chatId in chatIds {
            let oldestMessageId = items
                .filter { $0.chatId == chatId }
                .flatMap(\.representedMessageIds)
                .min()

            if let oldestMessageId {
                channelOldestMessageIDs[chatId] = oldestMessageId
            }
        }
    }

    private func filterMessagesToVisibleRange(_ messages: [Message]) -> [Message] {
        guard let earliestVisibleDate else { return messages }
        return messages.filter { $0.date >= earliestVisibleDate }
    }

    private static func startOfCurrentDayTimestamp() -> Int {
        Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    }

    private func applyIncomingMessage(_ message: Message, allowBuffering: Bool = true) {
        guard activeChannelIDs.contains(message.chatId) else { return }
        guard shouldDisplayInCurrentHistoryWindow(message) else { return }

        if allowBuffering && (isLoading || channels[message.chatId] == nil) {
            guard !bufferedIncomingMessages.contains(where: { $0.id == message.id }) else { return }
            bufferedIncomingMessages.append(message)
            return
        }

        guard let item = makeItem(from: message) else { return }
        guard !representedMessageIDs(in: items, chatId: message.chatId).contains(item.id) else {
            return
        }

        let visibleDelta = insertItemsMerged([item])
        if visibleDelta > 0, !isRead(item) {
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

    private func reconcileMessage(chatId: Int64, messageId: Int64) async {
        guard activeChannelIDs.contains(chatId) else { return }

        let wasAlreadyInFeedWindow = containsRepresentedMessage(chatId: chatId, messageId: messageId)
        removeMessages(chatId: chatId, messageIds: [messageId])

        guard let message = try? await TDLibService.shared.getMessage(
            chatId: chatId,
            messageId: messageId
        ) else {
            rebuildHistoryCursors(for: Set([chatId]))
            return
        }

        guard shouldDisplayInCurrentHistoryWindow(message) || wasAlreadyInFeedWindow else {
            rebuildHistoryCursors(for: Set([chatId]))
            return
        }

        let replacements = await replacementItems(for: message)
        if !replacements.isEmpty {
            insertItemsMerged(replacements)
        }
        rebuildHistoryCursors(for: Set([chatId]))
    }

    private func replacementItems(for message: Message) async -> [FeedItem] {
        guard let albumID = normalizedAlbumID(for: message) else {
            return makeItems(from: [message])
        }

        let context = await fetchHistoryBatch(
            chatId: message.chatId,
            fromMessageId: message.id,
            limit: albumBoundaryFetchSize,
            offset: -(albumBoundaryFetchSize / 2)
        )

        let albumMessages = uniqueMessages(context + [message]).filter {
            normalizedAlbumID(for: $0) == albumID
        }

        let expandedAlbum = await expandAlbumEdges(
            chatId: message.chatId,
            messages: albumMessages
        )

        return makeItems(from: expandedAlbum)
    }

    private func removeMessages(chatId: Int64, messageIds: Set<Int64>) {
        guard !messageIds.isEmpty else { return }

        performStableMutation {
            items = prune(items, for: chatId, removing: messageIds)
            deferredOlderItems = prune(deferredOlderItems, for: chatId, removing: messageIds)
        }
        recalculateVisibleHistoryLowerBound()
        bufferedIncomingMessages.removeAll {
            $0.chatId == chatId && messageIds.contains($0.id)
        }
        rebuildHistoryCursors(for: Set([chatId]))
    }

    private func affectedAlbumRebuildAnchors(for chatId: Int64, removing messageIds: Set<Int64>) -> [Int64] {
        guard !messageIds.isEmpty else { return [] }

        return Array(
            Set(
                (items + deferredOlderItems).compactMap { item in
                    guard item.chatId == chatId,
                          item.mediaAlbumId != nil,
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

    private func restoreAffectedAlbums(chatId: Int64, survivingMessageIds: [Int64]) async {
        guard !survivingMessageIds.isEmpty else { return }

        let currentOldestVisibleItem = items.first

        for messageId in survivingMessageIds.sorted() {
            guard let message = try? await TDLibService.shared.getMessage(
                chatId: chatId,
                messageId: messageId
            ) else {
                continue
            }

            let replacements = await replacementItems(for: message)
            guard !replacements.isEmpty else { continue }

            if let currentOldestVisibleItem {
                let hidden = replacements.filter { $0 < currentOldestVisibleItem }
                let visible = replacements.filter { !($0 < currentOldestVisibleItem) }
                if !hidden.isEmpty {
                    bufferDeferredOlderItems(hidden)
                }
                if !visible.isEmpty {
                    insertItemsMerged(visible)
                }
            } else {
                insertItemsMerged(replacements)
            }
        }

        rebuildHistoryCursors(for: Set([chatId]))
    }

    private func prune(_ source: [FeedItem], for chatId: Int64, removing messageIds: Set<Int64>) -> [FeedItem] {
        source.compactMap { item in
            guard item.chatId == chatId else { return item }

            let remainingIds = item.representedMessageIds.filter { !messageIds.contains($0) }
            guard remainingIds.count != item.representedMessageIds.count else { return item }
            guard !remainingIds.isEmpty else { return nil }

            // Aggregated album cards can't safely remove a single message in place.
            guard item.mediaAlbumId == nil else { return nil }

            return copy(
                item,
                messageId: remainingIds.max() ?? item.messageId,
                representedMessageIds: remainingIds
            )
        }
    }

    private func handleChatMetadataChange(_ channel: ChannelInfo) {
        channels[channel.id] = channel

        performStableMutation {
            items = items.map { item in
                guard item.chatId == channel.id else { return item }
                return copy(
                    item,
                    channelTitle: channel.title,
                    avatarFileId: channel.avatarFileId
                )
            }
            deferredOlderItems = deferredOlderItems.map { item in
                guard item.chatId == channel.id else { return item }
                return copy(
                    item,
                    channelTitle: channel.title,
                    avatarFileId: channel.avatarFileId
                )
            }
        }
    }

    private func refreshChannelMetadata(chatId: Int64) async {
        guard let chat = try? await TDLibService.shared.getChat(chatId: chatId),
              case .chatTypeSupergroup = chat.type else {
            return
        }

        lastReadInboxMessageIDs[chatId] = chat.lastReadInboxMessageId
        handleChatMetadataChange(
            ChannelInfo(
                id: chat.id,
                title: chat.title,
                avatarFileId: chat.photo?.small.id
            )
        )
    }

    private func scheduleChannelMetadataRefresh(chatId: Int64) {
        guard pendingMetadataRefreshChatIDs.insert(chatId).inserted else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pendingMetadataRefreshChatIDs.remove(chatId) }
            await refreshChannelMetadata(chatId: chatId)
        }
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

    private func copy(
        _ item: FeedItem,
        messageId: Int64? = nil,
        formattedText: FormattedText? = nil,
        channelTitle: String? = nil,
        avatarFileId: Int?? = nil,
        reactions: [FeedItem.Reaction]? = nil,
        representedMessageIds: [Int64]? = nil,
        mediaItems: [MediaInfo]? = nil
    ) -> FeedItem {
        FeedItem(
            chatId: item.chatId,
            messageId: messageId ?? item.messageId,
            date: item.date,
            formattedText: formattedText ?? item.formattedText,
            channelTitle: channelTitle ?? item.channelTitle,
            avatarFileId: avatarFileId ?? item.avatarFileId,
            reactions: reactions ?? item.reactions,
            mediaAlbumId: item.mediaAlbumId,
            representedMessageIds: representedMessageIds ?? item.representedMessageIds,
            mediaItems: mediaItems ?? item.mediaItems
        )
    }

    private func makeItems(from messages: [Message]) -> [FeedItem] {
        normalizeItems(messages.compactMap { makeItem(from: $0) })
    }

    @discardableResult
    private func insertItemsMerged(_ newItems: [FeedItem]) -> Int {
        guard !newItems.isEmpty else { return 0 }

        let existingIDs = representedMessageIDs(in: items + deferredOlderItems, chatId: nil)
        let uniqueNewItems = newItems.filter { newItem in
            let isDuplicate = newItem.representedMessageIds.allSatisfy {
                existingIDs.contains(FeedItemID(chatId: newItem.chatId, messageId: $0))
            }
            return !isDuplicate
        }

        guard !uniqueNewItems.isEmpty else { return 0 }

        let previousCount = items.count

        performStableMutation {
            for newItem in uniqueNewItems {
                if let mergedItem = mergeIntoExistingAlbumIfNeeded(newItem) {
                    insertSorted(mergedItem)
                } else {
                    insertSorted(newItem)
                }
            }
        }

        return items.count - previousCount
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

    private func drainDeferredOlderItems(before anchorItem: FeedItem?) -> [FeedItem] {
        guard !deferredOlderItems.isEmpty else { return [] }

        let eligibleItems = deferredOlderItems.filter { item in
            guard let anchorItem else { return true }
            return item < anchorItem
        }
        guard !eligibleItems.isEmpty else { return [] }

        let eligibleIDs = Set(eligibleItems.map(\.id))
        deferredOlderItems.removeAll { eligibleIDs.contains($0.id) }
        return eligibleItems.sorted()
    }

    private func preferredInitialAnchorID() -> FeedItemID? {
        if let firstUnread = items.first(where: { !isRead($0) }) {
            return firstUnread.id
        }
        return items.last?.id
    }

    private func prepareWindow(
        around targetID: FeedItemID,
        keepingPreviewCount _: Int
    ) async -> FeedItemID? {
        guard !items.isEmpty else { return nil }

        guard let resolvedTarget = items.first(where: { $0.matches(targetID) })?.id else {
            return nil
        }

        return resolvedTarget
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
        recalculateVisibleHistoryLowerBound()
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
            insertItemsMerged(
                additions.filter { item in
                    earliestVisibleDate.map { item.date >= $0 } ?? true
                }
            )
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
        var seen: Set<FeedItemID> = []
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
                .filter { seen.insert(messageKey(for: $0)).inserted }

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
        var seen: Set<FeedItemID> = []
        return messages.filter { seen.insert(messageKey(for: $0)).inserted }
    }

    private func messageKey(for message: Message) -> FeedItemID {
        FeedItemID(chatId: message.chatId, messageId: message.id)
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

    private func extendVisibleHistoryLowerBound(with items: [FeedItem]) {
        guard let minDate = items.map(\.date).min() else { return }
        if let earliestVisibleDate {
            self.earliestVisibleDate = min(earliestVisibleDate, minDate)
        } else {
            earliestVisibleDate = minDate
        }
    }

    private func recalculateVisibleHistoryLowerBound() {
        let minimumLoadedDate = (items + deferredOlderItems).map(\.date).min()

        if let currentDayFloor {
            if let minimumLoadedDate {
                earliestVisibleDate = min(currentDayFloor, minimumLoadedDate)
            } else {
                earliestVisibleDate = currentDayFloor
            }
        } else {
            earliestVisibleDate = minimumLoadedDate
        }
    }

    private func shouldDisplayInCurrentHistoryWindow(_ message: Message) -> Bool {
        guard message.content.shouldAppearInFeed else { return false }
        guard let earliestVisibleDate else { return true }
        return message.date >= earliestVisibleDate
    }

    private func containsRepresentedMessage(chatId: Int64, messageId: Int64) -> Bool {
        representedMessageIDs(in: items + deferredOlderItems, chatId: chatId)
            .contains(FeedItemID(chatId: chatId, messageId: messageId))
    }
}

private enum AlbumBoundaryDirection {
    case older
    case newer
}

private struct ChannelLoadResult: Sendable {
    let chatId: Int64
    let messages: [Message]
    let reachedOldest: Bool
    let historyCursorMessageId: Int64?
    let hiddenOlderPreviewMessages: [Message]
}
