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
    @State private var pendingProgrammaticScrollTarget: FeedItemID?
    @State private var pendingProgrammaticScrollAnchor: UnitPoint = .center
    @State private var pendingProgrammaticScrollAnimated = false
    @State private var hasScheduledInitialPlacement = false
    @State private var isApplyingChannelChanges = false

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
            pendingProgrammaticScrollTarget = nil
            hasScheduledInitialPlacement = false
            scrollPosition = nil
            await viewModel.load(
                selectedIDs: appState.selectedChannelIDs,
                restoredPosition: pendingRestoredPosition
            )
            restoreScrollPositionIfPossible()
        }
        .onDisappear {
            viewModel.stopListening()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active, let position = scrollPosition {
                ScrollPositionStore.saveIfNeeded(position)
            }
        }
        .onChange(of: viewModel.items) { _, _ in
            restoreScrollPositionIfPossible()
        }
        .onChange(of: appState.selectedChannelIDs) { _, newIDs in
            Task {
                let previousItems = viewModel.items
                let previousPosition = scrollPosition
                    ?? pendingProgrammaticScrollTarget
                    ?? lastVisiblePosition
                    ?? pendingRestoredPosition

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
                    previousTarget: previousPosition
                ) {
                    scheduleScroll(to: replacement)
                }
            }
        }
        .onChange(of: viewModel.pendingScrollToItemID) { _, target in
            guard let target else { return }
            if let resolvedTarget = resolvedItemID(for: target) {
                scheduleScroll(to: resolvedTarget, anchor: .bottom, animated: true)
            }
            viewModel.consumePendingScrollRequest()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(channels: viewModel.channels)
        }
        .sheet(item: $selectedChannel) { channel in
            ChannelSheetView(channelInfo: channel, scrollTo: selectedMessageId)
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
                        restoredPosition: scrollPosition
                            ?? pendingProgrammaticScrollTarget
                            ?? lastVisiblePosition
                            ?? pendingRestoredPosition
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
                        FeedCardView(item: item, onChannelTap: {
                            if let channel = viewModel.channels[item.chatId] {
                                selectedMessageId = item.id
                                selectedChannel = channel
                            }
                        }, onTelegramLinkTap: { target in
                            if let channel = viewModel.channels[target.chatId] {
                                selectedMessageId = target
                                selectedChannel = channel
                            }
                        }, onPostReferenceTap: { reference in
                            if let channel = viewModel.channels[reference.target.chatId] {
                                selectedMessageId = reference.target
                                selectedChannel = channel
                            }
                        })
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
                    restoredPosition: scrollPosition
                        ?? pendingProgrammaticScrollTarget
                        ?? lastVisiblePosition
                        ?? pendingRestoredPosition
                )
            }
            .onChange(of: self.scrollPosition) { _, newValue in
                if newValue == nil,
                   (pendingRestoredPosition != nil || pendingProgrammaticScrollTarget != nil || isApplyingChannelChanges) {
                    return
                }
                if let newValue {
                    lastVisiblePosition = newValue
                }
                if newValue == pendingProgrammaticScrollTarget {
                    pendingProgrammaticScrollTarget = nil
                    if let restoredPosition = pendingRestoredPosition,
                       viewModel.items.first(where: { $0.matches(restoredPosition) })?.id == newValue {
                        pendingRestoredPosition = nil
                    }
                }
                ScrollPositionStore.saveIfNeeded(newValue)
                viewModel.updateScrollPosition(newValue)
                if let pos = newValue,
                   let first = viewModel.items.first,
                   pos == first.id {
                    Task {
                        await viewModel.loadOlder()
                    }
                }
            }
            .onChange(of: pendingProgrammaticScrollTarget) { _, target in
                guard let target else { return }
                let anchor = pendingProgrammaticScrollAnchor
                let animated = pendingProgrammaticScrollAnimated
                Task { @MainActor in
                    await Task.yield()
                    guard pendingProgrammaticScrollTarget == target else { return }
                    if animated {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: anchor)
                        }
                    } else {
                        proxy.scrollTo(target, anchor: anchor)
                    }
                    scrollPosition = target
                    await Task.yield()
                    proxy.scrollTo(target, anchor: anchor)
                    scrollPosition = target
                    if let restoredPosition = pendingRestoredPosition,
                       viewModel.items.first(where: { $0.matches(restoredPosition) })?.id == target {
                        pendingRestoredPosition = nil
                    }
                    pendingProgrammaticScrollTarget = nil
                    pendingProgrammaticScrollAnimated = false
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.isAtBottom {
                scrollToBottomButton
                    .padding(20)
            }
        }
    }

    private var scrollToBottomButton: some View {
        Button {
            if let last = viewModel.items.last {
                scheduleScroll(to: last.id, anchor: .bottom, animated: true)
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
    }

    private func restoreScrollPositionIfPossible() {
        guard pendingProgrammaticScrollTarget == nil else { return }

        if let pendingRestoredPosition {
            if let matching = viewModel.items.first(where: { $0.matches(pendingRestoredPosition) }) {
                hasScheduledInitialPlacement = true
                scheduleScroll(to: matching.id)
                return
            }

            if viewModel.isLoading {
                return
            }

            self.pendingRestoredPosition = nil
        }

        guard !hasScheduledInitialPlacement, scrollPosition == nil, let newest = viewModel.items.last else { return }
        hasScheduledInitialPlacement = true
        scheduleScroll(to: newest.id, anchor: .bottom)
    }

    private func scheduleScroll(
        to target: FeedItemID,
        anchor: UnitPoint = .center,
        animated: Bool = false
    ) {
        pendingProgrammaticScrollTarget = target
        pendingProgrammaticScrollAnchor = anchor
        pendingProgrammaticScrollAnimated = animated
        if anchor == .bottom {
            viewModel.scrolledToBottom()
        }
    }

    private func resolvedItemID(for target: FeedItemID, in items: [FeedItem]? = nil) -> FeedItemID? {
        let source = items ?? viewModel.items
        return source.first(where: { $0.matches(target) })?.id
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

}
