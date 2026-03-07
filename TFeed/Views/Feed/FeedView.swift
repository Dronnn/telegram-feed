import SwiftUI
import SwiftData

struct FeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel = FeedViewModel()
    @State private var isContentReady = false
    @State private var pendingScrollID: FeedItemID?
    @State private var viewportAnchorID: FeedItemID?
    @State private var readingAnchorID: FeedItemID?
    @State private var lastVisiblePosition: FeedItemID?
    @State private var showSettings = false
    @State private var presentedChannelTarget: PresentedChannelTarget?
    @State private var isApplyingChannelChanges = false
    @State private var isScrollActive = false
    @State private var isViewportAtBottom = true
    @State private var channelChangeTask: Task<Void, Never>?
    @State private var loadOlderTask: Task<Void, Never>?
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var scrollPosition = ScrollPosition()
    @State private var bottomRefreshArmed = false
    @State private var bottomPullDistance: CGFloat = 0
    @State private var isUserDraggingFeed = false
    @State private var canLoadOlderFromUserScroll = false
    @State private var hasLoadedOlderInCurrentDrag = false

    private let bottomRefreshThreshold: CGFloat = 60

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
                } else if !isContentReady {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            viewportAnchorID = nil
            readingAnchorID = nil
            lastVisiblePosition = nil
            isContentReady = false
            canLoadOlderFromUserScroll = false
            isUserDraggingFeed = false
            hasLoadedOlderInCurrentDrag = false
            await viewModel.load(selectedIDs: appState.selectedChannelIDs)
            setupScrollPosition()
            isContentReady = true
        }
        .onDisappear {
            loadOlderTask?.cancel()
            refreshTask?.cancel()
            channelChangeTask?.cancel()
            viewModel.stopListening()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                Task { await viewModel.flushPendingReadState() }
            }
        }
        .onChange(of: appState.selectedChannelIDs) { _, newIDs in
            channelChangeTask?.cancel()
            loadOlderTask?.cancel()
            loadOlderTask = nil
            channelChangeTask = Task {
                let previousItems = viewModel.items
                let previousTarget = currentAnchorTarget()

                isApplyingChannelChanges = true
                await viewModel.applyChannelChanges(newIDs: newIDs)
                isApplyingChannelChanges = false

                guard !viewModel.items.isEmpty else {
                    viewportAnchorID = nil
                    readingAnchorID = nil
                    lastVisiblePosition = nil
                    return
                }

                if let replacement = replacementScrollTarget(
                    after: viewModel.items,
                    previousItems: previousItems,
                    previousTarget: previousTarget
                ) {
                    pendingScrollID = replacement
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(channels: viewModel.channels)
        }
        .sheet(item: $presentedChannelTarget) { target in
            ChannelSheetView(channelInfo: target.channel, scrollTo: target.messageId) { chatId, lastReadMessageId in
                viewModel.syncReadState(
                    chatId: chatId,
                    lastReadMessageId: lastReadMessageId,
                    currentPosition: currentAnchorTarget()
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

    private func setupScrollPosition() {
        if let anchorID = viewModel.initialAnchorID,
           let resolved = resolvedItemID(for: anchorID) {
            viewModel.initialAnchorID = nil
            scrollPosition = ScrollPosition(id: resolved, anchor: .center)
            viewportAnchorID = resolved
            readingAnchorID = resolved
            lastVisiblePosition = resolved
        } else if let newest = viewModel.items.last {
            scrollPosition = ScrollPosition(id: newest.id, anchor: .bottom)
            viewportAnchorID = newest.id
            readingAnchorID = newest.id
            lastVisiblePosition = newest.id
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
                    isContentReady = false
                    await viewModel.load(selectedIDs: appState.selectedChannelIDs)
                    setupScrollPosition()
                    isContentReady = true
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    private var feedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.items) { item in
                    FeedCardView(
                        item: item,
                        isRead: viewModel.isRead(item),
                        onChannelTap: { openChannel(for: item.id) },
                        onTelegramLinkTap: { target in openChannel(for: target) },
                        onPostReferenceTap: { reference in openChannel(for: reference.target) }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .id(item.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollTargetLayout()
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollPosition($scrollPosition)
        .onScrollTargetVisibilityChange(idType: FeedItemID.self, threshold: 0.01) { visibleIDs in
            handleVisibleTargets(visibleIDs)
        }
        .overlay(alignment: .top) {
            if viewModel.isLoadingMore {
                loadingOverlay
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) {
            if isRefreshing || bottomPullDistance > 0 {
                bottomRefreshOverlay
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: pendingScrollID) { _, target in
            guard let target else { return }
            pendingScrollID = nil
            scrollPosition.scrollTo(id: target, anchor: .center)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    if !isUserDraggingFeed {
                        hasLoadedOlderInCurrentDrag = false
                    }
                    isUserDraggingFeed = true
                }
                .onEnded { _ in
                    isUserDraggingFeed = false
                    canLoadOlderFromUserScroll = false
                    hasLoadedOlderInCurrentDrag = false
                    completeBottomRefreshIfNeeded()
                }
        )
        .onScrollPhaseChange { _, newPhase in
            isScrollActive = newPhase.isScrolling
            if newPhase.isScrolling {
                loadOlderTask?.cancel()
                loadOlderTask = nil
            } else {
                canLoadOlderFromUserScroll = false
                if !isUserDraggingFeed {
                    hasLoadedOlderInCurrentDrag = false
                }
            }
        }
        .onScrollGeometryChange(
            for: Bool.self,
            of: { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                return visibleBottom >= geometry.contentSize.height - 24
            },
            action: { _, newValue in
                isViewportAtBottom = newValue
                viewModel.updateBottomState(newValue, currentPosition: currentAnchorTarget())
            }
        )
        .onScrollGeometryChange(
            for: Bool.self,
            of: { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                let overscroll = max(visibleBottom - geometry.contentSize.height, 0)
                return overscroll >= bottomRefreshThreshold
            },
            action: { _, triggered in
                guard !isRefreshing else { return }
                if triggered {
                    bottomRefreshArmed = true
                }
            }
        )
        .onScrollGeometryChange(
            for: CGFloat.self,
            of: { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                return max(visibleBottom - geometry.contentSize.height, 0)
            },
            action: { _, newValue in
                guard !isRefreshing else { return }
                bottomPullDistance = newValue
                if newValue <= 0 {
                    bottomRefreshArmed = false
                }
            }
        )
        .onScrollGeometryChange(
            for: CGFloat.self,
            of: { geometry in geometry.contentOffset.y },
            action: { oldValue, newValue in
                guard isUserDraggingFeed, !hasLoadedOlderInCurrentDrag else { return }
                if newValue < oldValue - 8 {
                    canLoadOlderFromUserScroll = true
                } else if newValue > oldValue + 8 {
                    canLoadOlderFromUserScroll = false
                }
            }
        )
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.isAtBottom || viewModel.unreadCount > 0 {
                Button {
                    scrollToBottom()
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
                    .background(Color.clear, in: Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to bottom")
                .zIndex(1)
                .transition(.scale.combined(with: .opacity))
                .padding(20)
            }
        }
    }

    private var loadingOverlay: some View {
        ProgressView()
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var bottomRefreshOverlay: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(bottomRefreshLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(isRefreshing || bottomPullDistance > 0 ? 1 : 0)
    }

    private var bottomRefreshLabel: String {
        if isRefreshing {
            return "Refreshing today"
        }
        if bottomRefreshArmed || bottomPullDistance >= bottomRefreshThreshold {
            return "Release to refresh"
        }
        return "Pull to refresh"
    }

    private func handleVisibleTargets(_ visibleIDs: [FeedItemID]) {
        let orderedVisibleIDs = orderedVisibleTargets(from: visibleIDs)
        let topAnchor = orderedVisibleIDs.first.flatMap { resolvedItemID(for: $0) }
        let readingAnchor = orderedVisibleIDs.isEmpty
            ? nil
            : resolvedItemID(for: orderedVisibleIDs[orderedVisibleIDs.count / 2])

        if let topAnchor {
            viewportAnchorID = topAnchor
            lastVisiblePosition = topAnchor
            readingAnchorID = readingAnchor ?? topAnchor
        } else if isApplyingChannelChanges {
            return
        }

        guard let visibleAnchor = readingAnchor ?? topAnchor else { return }

        viewModel.updateBottomState(isViewportAtBottom, currentPosition: visibleAnchor)
        viewModel.scheduleMarkAsRead(currentPosition: visibleAnchor)
        requestLoadOlderIfNeeded(at: topAnchor)
    }

    private func resolvedItemID(for target: FeedItemID, in items: [FeedItem]? = nil) -> FeedItemID? {
        let source = items ?? viewModel.items
        return source.first(where: { $0.matches(target) })?.id
    }

    private func currentAnchorTarget() -> FeedItemID? {
        readingAnchorID ?? viewportAnchorID ?? lastVisiblePosition
    }

    private func currentTopAnchorTarget() -> FeedItemID? {
        viewportAnchorID ?? lastVisiblePosition
    }

    private func orderedVisibleTargets(from visibleIDs: [FeedItemID]) -> [FeedItemID] {
        let indexByID = Dictionary(uniqueKeysWithValues: viewModel.items.enumerated().map { ($1.id, $0) })
        return visibleIDs.sorted { (indexByID[$0] ?? .max) < (indexByID[$1] ?? .max) }
    }

    private func requestLoadOlderIfNeeded(at topAnchor: FeedItemID?) {
        guard !isApplyingChannelChanges,
              !isRefreshing,
              isUserDraggingFeed,
              canLoadOlderFromUserScroll,
              let topAnchor,
              loadOlderTask == nil else {
            return
        }

        canLoadOlderFromUserScroll = false
        loadOlderTask?.cancel()
        loadOlderTask = Task { @MainActor in
            let didLoadOlder = await viewModel.loadOlderIfNeeded(currentPosition: topAnchor)
            guard !Task.isCancelled else {
                loadOlderTask = nil
                return
            }

            if didLoadOlder {
                await Task.yield()

                if let restoredTop = resolvedItemID(for: topAnchor) {
                    viewportAnchorID = restoredTop
                    lastVisiblePosition = restoredTop
                    scrollPosition.scrollTo(id: restoredTop, anchor: .top)
                }
            }

            hasLoadedOlderInCurrentDrag = didLoadOlder

            loadOlderTask = nil
        }
    }

    private func triggerBottomRefresh() {
        refreshTask?.cancel()
        isRefreshing = true
        bottomPullDistance = 0
        bottomRefreshArmed = false
        canLoadOlderFromUserScroll = false
        hasLoadedOlderInCurrentDrag = false
        isUserDraggingFeed = false
        let previousItems = viewModel.items
        let previousTarget = currentTopAnchorTarget() ?? currentAnchorTarget()

        refreshTask = Task { @MainActor in
            async let minimumDelay: () = Task.sleep(for: .milliseconds(800))
            await viewModel.reloadCurrentDay(selectedIDs: appState.selectedChannelIDs)

            if let replacement = replacementScrollTarget(
                after: viewModel.items,
                previousItems: previousItems,
                previousTarget: previousTarget
            ) {
                viewModel.initialAnchorID = nil
                viewportAnchorID = replacement
                readingAnchorID = replacement
                lastVisiblePosition = replacement
                let isAtBottom = replacement == viewModel.items.last?.id
                viewModel.updateBottomState(isAtBottom, currentPosition: replacement)
                scrollPosition = ScrollPosition(
                    id: replacement,
                    anchor: isAtBottom ? .bottom : .top
                )
            } else {
                setupScrollPosition()
            }

            _ = await (try? minimumDelay)
            isRefreshing = false
        }
    }

    private func completeBottomRefreshIfNeeded() {
        guard bottomRefreshArmed,
              bottomPullDistance >= bottomRefreshThreshold,
              !isRefreshing else { return }
        bottomRefreshArmed = false
        triggerBottomRefresh()
    }

    private func scrollToBottom() {
        guard let newest = viewModel.items.last else { return }

        pendingScrollID = nil
        viewportAnchorID = newest.id
        readingAnchorID = newest.id
        lastVisiblePosition = newest.id
        viewModel.updateBottomState(true, currentPosition: newest.id)

        withAnimation {
            scrollPosition.scrollTo(id: newest.id, anchor: .bottom)
        }
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

    private func openChannel(for target: FeedItemID) {
        guard let channel = viewModel.channels[target.chatId] else { return }
        presentedChannelTarget = PresentedChannelTarget(channel: channel, messageId: target)
    }
}

private struct PresentedChannelTarget: Identifiable {
    let channel: ChannelInfo
    let messageId: FeedItemID

    var id: String {
        "\(channel.id):\(messageId.messageId)"
    }
}
