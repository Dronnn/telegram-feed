import SwiftUI
import SwiftData

struct FeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel = FeedViewModel()
    @State private var scrollPosition: FeedItemID?
    @State private var lastVisiblePosition: FeedItemID?
    @State private var showSettings = false
    @State private var selectedChannel: ChannelInfo?
    @State private var selectedMessageId: FeedItemID?
    @State private var pendingRestoredPosition: FeedItemID?
    @State private var pendingScrollRequest: FeedScrollRequest?
    @State private var didScheduleInitialPlacement = false
    @State private var isApplyingChannelChanges = false
    @State private var isPerformingProgrammaticScroll = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage, viewModel.items.isEmpty {
                    errorState(errorMessage)
                } else if viewModel.items.isEmpty {
                    emptyState
                } else {
                    feedContent
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .task {
            loadSelectedChannelsFromSwiftData()
            pendingRestoredPosition = ScrollPositionStore.load()
            pendingScrollRequest = nil
            didScheduleInitialPlacement = false
            isPerformingProgrammaticScroll = false
            scrollPosition = nil
            await viewModel.load(
                selectedIDs: appState.selectedChannelIDs,
                restoredPosition: pendingRestoredPosition
            )
            restoreScrollPositionIfPossible()
        }
        .onDisappear {
            saveTask?.cancel()
            if let position = scrollPosition ?? lastVisiblePosition {
                savePosition(position)
            }
            viewModel.stopListening()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                saveTask?.cancel()
                if let position = scrollPosition ?? lastVisiblePosition {
                    savePosition(position)
                }
            }
        }
        .onChange(of: viewModel.items) { _, _ in
            restoreScrollPositionIfPossible()
        }
        .onChange(of: appState.selectedChannelIDs) { _, newIDs in
            Task {
                let previousItems = viewModel.items
                let previousTarget = currentAnchorTarget()

                isApplyingChannelChanges = true
                await viewModel.applyChannelChanges(newIDs: newIDs)
                isApplyingChannelChanges = false

                guard !viewModel.items.isEmpty else {
                    scrollPosition = nil
                    lastVisiblePosition = nil
                    return
                }

                if let replacement = replacementScrollTarget(
                    after: viewModel.items,
                    previousItems: previousItems,
                    previousTarget: previousTarget
                ) {
                    requestScroll(to: replacement, anchor: .center)
                }
            }
        }
        .onChange(of: viewModel.pendingScrollToItemID) { _, target in
            guard let target else { return }
            if let resolvedTarget = resolvedItemID(for: target) {
                requestScroll(to: resolvedTarget, anchor: .bottom, animated: true)
            }
            viewModel.consumePendingScrollRequest()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(channels: viewModel.channels)
        }
        .sheet(item: $selectedChannel) { channel in
            ChannelSheetView(channelInfo: channel, scrollTo: selectedMessageId) { chatId, lastReadMessageId in
                viewModel.syncReadState(
                    chatId: chatId,
                    lastReadMessageId: lastReadMessageId,
                    currentPosition: scrollPosition ?? lastVisiblePosition
                )
            }
        }
    }

    private func loadSelectedChannelsFromSwiftData() {
        let descriptor = FetchDescriptor<SelectedChannel>()
        if let saved = try? modelContext.fetch(descriptor), !saved.isEmpty {
            appState.selectedChannelIDs = Set(saved.map(\.chatId))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Select channels to read")
                .font(.title2.weight(.semibold))

            Text("Open settings and choose which channels appear in your feed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Connection Issue")
                .font(.title2.weight(.semibold))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task {
                    await viewModel.refresh(
                        selectedIDs: appState.selectedChannelIDs,
                        restoredPosition: currentAnchorTarget()
                    )
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    private var feedContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    if viewModel.isLoadingMore {
                        ProgressView()
                            .padding()
                    }

                    ForEach(viewModel.items) { item in
                        FeedCardView(
                            item: item,
                            isRead: viewModel.isRead(item),
                            onChannelTap: { openChannel(for: item.id) },
                            onTelegramLinkTap: { target in openChannel(for: target) },
                            onPostReferenceTap: { reference in openChannel(for: reference.target) }
                        )
                        .padding(.horizontal, 16)
                        .id(item.id)
                    }
                }
                .padding(.vertical, 12)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollPosition)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .refreshable {
                await viewModel.refresh(
                    selectedIDs: appState.selectedChannelIDs,
                    restoredPosition: currentAnchorTarget()
                )
            }
            .onChange(of: scrollPosition) { _, newValue in
                if newValue == nil,
                   (pendingRestoredPosition != nil || pendingScrollRequest != nil || isApplyingChannelChanges || isPerformingProgrammaticScroll) {
                    return
                }

                if let newValue {
                    lastVisiblePosition = newValue
                }

                debounceSavePosition(newValue)
                viewModel.updateScrollPosition(newValue)
                viewModel.trimTopIfNeeded(currentPosition: newValue)
                viewModel.scheduleMarkAsRead(currentPosition: newValue)

                guard let pos = newValue, !isPerformingProgrammaticScroll else { return }
                Task { await viewModel.loadOlderIfNeeded(currentPosition: pos) }
            }
            .onChange(of: pendingScrollRequest) { _, request in
                guard let request else { return }
                let anchor: UnitPoint = request.anchor == .bottom ? .bottom : .center
                Task { @MainActor in
                    isPerformingProgrammaticScroll = true
                    await Task.yield()
                    guard pendingScrollRequest == request else {
                        isPerformingProgrammaticScroll = false
                        return
                    }
                    if request.animated {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(request.target, anchor: anchor)
                        }
                    } else {
                        proxy.scrollTo(request.target, anchor: anchor)
                    }
                    if let pendingRestoredPosition,
                       resolvedItemID(for: pendingRestoredPosition) == request.target {
                        self.pendingRestoredPosition = nil
                    }
                    pendingScrollRequest = nil
                    await Task.yield()
                    isPerformingProgrammaticScroll = false
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.isAtBottom || viewModel.unreadCount > 0 {
                scrollToBottomButton
                    .padding(20)
            }
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            guard let last = viewModel.items.last else { return }
            requestScroll(to: last.id, anchor: .bottom, animated: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))

                if viewModel.unreadCount > 0 {
                    Text("\(viewModel.unreadCount)")
                        .font(.caption2.weight(.bold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    private func restoreScrollPositionIfPossible() {
        guard pendingScrollRequest == nil, !isPerformingProgrammaticScroll else { return }

        if let pendingRestoredPosition {
            if let resolvedTarget = resolvedItemID(for: pendingRestoredPosition) {
                didScheduleInitialPlacement = true
                requestScroll(to: resolvedTarget, anchor: .center)
                return
            }

            if viewModel.isLoading {
                return
            }

            self.pendingRestoredPosition = nil
        }

        guard !didScheduleInitialPlacement, scrollPosition == nil, !viewModel.items.isEmpty else { return }
        didScheduleInitialPlacement = true
        if let anchorID = viewModel.initialAnchorID {
            viewModel.initialAnchorID = nil
            requestScroll(to: anchorID, anchor: .center)
        } else if let newest = viewModel.items.last {
            requestScroll(to: newest.id, anchor: .bottom)
        }
    }

    private func requestScroll(
        to target: FeedItemID,
        anchor: FeedScrollRequest.Anchor,
        animated: Bool = false
    ) {
        pendingScrollRequest = FeedScrollRequest(target: target, anchor: anchor, animated: animated)
        if anchor == .bottom {
            viewModel.scrolledToBottom()
        }
    }

    private func resolvedItemID(for target: FeedItemID, in items: [FeedItem]? = nil) -> FeedItemID? {
        let source = items ?? viewModel.items
        return source.first(where: { $0.matches(target) })?.id
    }

    private func currentAnchorTarget() -> FeedItemID? {
        scrollPosition
            ?? pendingScrollRequest?.target
            ?? lastVisiblePosition
            ?? pendingRestoredPosition
    }

    private func replacementScrollTarget(
        after newItems: [FeedItem],
        previousItems: [FeedItem],
        previousTarget: FeedItemID?
    ) -> FeedItemID? {
        if let previousTarget,
           let resolved = resolvedItemID(for: previousTarget, in: newItems) {
            return resolved
        }

        if let previousTarget,
           let previousIndex = previousItems.firstIndex(where: { $0.matches(previousTarget) }) {
            for distance in 1..<previousItems.count {
                let forwardIndex = previousIndex + distance
                if forwardIndex < previousItems.count,
                   let resolved = resolvedItemID(for: previousItems[forwardIndex].id, in: newItems) {
                    return resolved
                }

                let backwardIndex = previousIndex - distance
                if backwardIndex >= 0,
                   let resolved = resolvedItemID(for: previousItems[backwardIndex].id, in: newItems) {
                    return resolved
                }
            }
        }

        if let lastVisiblePosition,
           let resolved = resolvedItemID(for: lastVisiblePosition, in: newItems) {
            return resolved
        }

        return newItems.last?.id
    }

    private func savePosition(_ position: FeedItemID) {
        let date = viewModel.items.first(where: { $0.id == position })?.date ?? 0
        ScrollPositionStore.saveIfNeeded(position, date: date)
    }

    private func debounceSavePosition(_ position: FeedItemID?) {
        saveTask?.cancel()
        guard let position else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            savePosition(position)
        }
    }

    private func openChannel(for target: FeedItemID) {
        guard let channel = viewModel.channels[target.chatId] else { return }
        selectedMessageId = target
        selectedChannel = channel
    }
}

private struct FeedScrollRequest: Equatable {
    enum Anchor: Equatable {
        case center
        case bottom
    }

    let target: FeedItemID
    let anchor: Anchor
    let animated: Bool
}
