import SwiftUI
import SwiftData

struct FeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel = FeedViewModel()
    @State private var scrollPosition = ScrollPosition(idType: FeedItemID.self)
    @State private var isContentReady = false
    @State private var initialScrollAnchor: UnitPoint = .center
    @State private var viewportAnchorID: FeedItemID?
    @State private var readingAnchorID: FeedItemID?
    @State private var lastVisiblePosition: FeedItemID?
    @State private var showSettings = false
    @State private var selectedChannel: ChannelInfo?
    @State private var selectedMessageId: FeedItemID?
    @State private var isApplyingChannelChanges = false
    @State private var isScrollActive = false
    @State private var isViewportAtBottom = true
    @State private var channelChangeTask: Task<Void, Never>?
    @State private var trimTask: Task<Void, Never>?
    @State private var loadOlderTask: Task<Void, Never>?
    @State private var visibleItemIDs: Set<FeedItemID> = []
    @State private var didInitialScroll = false

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
            didInitialScroll = false
            isContentReady = false
            await viewModel.load(selectedIDs: appState.selectedChannelIDs)
            setupScrollPosition()
            isContentReady = true
        }
        .onDisappear {
            trimTask?.cancel()
            loadOlderTask?.cancel()
            viewModel.stopListening()
        }
        .onChange(of: appState.selectedChannelIDs) { _, newIDs in
            channelChangeTask?.cancel()
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
                    scrollPosition.scrollTo(id: replacement, anchor: .center)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(channels: viewModel.channels)
        }
        .sheet(item: $selectedChannel) { channel in
            ChannelSheetView(channelInfo: channel, scrollTo: selectedMessageId) { chatId, lastReadMessageId in
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
            initialScrollAnchor = .center
        } else if let newest = viewModel.items.last {
            scrollPosition = ScrollPosition(id: newest.id, anchor: .bottom)
            viewportAnchorID = newest.id
            readingAnchorID = newest.id
            lastVisiblePosition = newest.id
            initialScrollAnchor = .bottom
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
                    didInitialScroll = false
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
        ScrollViewReader { proxy in
            List {
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
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(item.id)
                    .onAppear {
                        visibleItemIDs.insert(item.id)
                        handleVisibleTargets(Array(visibleItemIDs))
                        triggerLoadOlderIfNeeded()
                    }
                    .onDisappear {
                        visibleItemIDs.remove(item.id)
                    }
                }
            }
            .scrollPosition($scrollPosition)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .listRowSpacing(0)
            .transaction { transaction in
                transaction.scrollPositionUpdatePreservesVelocity = true
                transaction.scrollContentOffsetAdjustmentBehavior = .automatic
            }
            .overlay(alignment: .top) {
                if viewModel.isLoadingMore {
                    loadingOverlay
                        .padding(.top, 8)
                }
            }
            .onAppear {
                if !didInitialScroll, let target = viewportAnchorID {
                    didInitialScroll = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        proxy.scrollTo(target, anchor: initialScrollAnchor)
                    }
                }
            }
            .onScrollPhaseChange { _, newPhase in
                isScrollActive = newPhase.isScrolling
                if newPhase.isScrolling {
                    loadOlderTask?.cancel()
                } else {
                    scheduleTrim(at: currentTopAnchorTarget())
                    loadOlderIfNeededAtRest()
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
            .overlay(alignment: .bottomTrailing) {
                if !viewModel.isAtBottom || viewModel.unreadCount > 0 {
                    Button {
                        if let last = viewModel.items.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
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
                    .padding(20)
                }
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

    private func scheduleTrim(at position: FeedItemID?) {
        trimTask?.cancel()
        guard let position, !isScrollActive else { return }

        trimTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            viewModel.trimTopIfNeeded(currentPosition: position)
        }
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
        scheduleTrim(at: topAnchor)
        viewModel.scheduleMarkAsRead(currentPosition: visibleAnchor)
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

    private func triggerLoadOlderIfNeeded() {
        guard !isApplyingChannelChanges,
              let topAnchor = viewportAnchorID,
              loadOlderTask == nil else {
            return
        }

        loadOlderTask = Task {
            defer { loadOlderTask = nil }
            _ = await viewModel.loadOlderIfNeeded(currentPosition: topAnchor)
        }
    }

    private func loadOlderIfNeededAtRest() {
        guard !isApplyingChannelChanges,
              let topAnchor = viewportAnchorID else {
            return
        }

        loadOlderTask?.cancel()
        loadOlderTask = Task {
            defer { loadOlderTask = nil }
            var anchor = topAnchor

            while !Task.isCancelled {
                let didLoad = await viewModel.loadOlderIfNeeded(currentPosition: anchor)
                guard didLoad else { return }

                let shouldContinue = await MainActor.run { () -> Bool in
                    guard !isApplyingChannelChanges,
                          let currentAnchor = viewportAnchorID else {
                        return false
                    }
                    anchor = currentAnchor
                    return true
                }

                guard shouldContinue else { return }
            }
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
        selectedMessageId = target
        selectedChannel = channel
    }
}
