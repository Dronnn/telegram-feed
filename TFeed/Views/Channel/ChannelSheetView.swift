import SwiftUI

struct ChannelSheetView: View {
    let channelInfo: ChannelInfo
    let initialMessageId: FeedItemID?
    var onReadStateChanged: ((Int64, Int64) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ChannelViewModel
    @State private var viewportAnchorID: FeedItemID?
    @State private var isContentReady = false
    @State private var isScrollActive = false
    @State private var trimTask: Task<Void, Never>?
    @State private var loadOlderTask: Task<Void, Never>?
    @State private var hasLoadedSinceRest = false
    @State private var scrollPosition = ScrollPosition()
    @State private var initialScrollTarget: FeedItemID?
    @State private var hasAppliedInitialScroll = false

    init(channelInfo: ChannelInfo, scrollTo messageId: FeedItemID? = nil, onReadStateChanged: ((Int64, Int64) -> Void)? = nil) {
        self.channelInfo = channelInfo
        self.initialMessageId = messageId
        self.onReadStateChanged = onReadStateChanged
        self._viewModel = State(initialValue: ChannelViewModel(channelInfo: channelInfo))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isContentReady {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.items.isEmpty {
                    Text("No messages")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList
                }
            }
            .navigationTitle(channelInfo.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    channelAvatar
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            trimTask?.cancel()
            loadOlderTask?.cancel()
            Task {
                await viewModel.flushPendingReadState()
                onReadStateChanged?(channelInfo.id, viewModel.lastReadInboxMessageId)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                Task { await viewModel.flushPendingReadState() }
            }
        }
        .task {
            viewportAnchorID = nil
            initialScrollTarget = nil
            hasAppliedInitialScroll = false
            isContentReady = false

            let resolvedTarget = await viewModel.load(aroundMessageId: initialMessageId?.messageId)
            guard !Task.isCancelled else { return }

            if initialMessageId != nil {
                guard let resolvedTarget else { return }
                initialScrollTarget = resolvedTarget
            } else {
                initialScrollTarget = resolvedTarget
            }

            isContentReady = true
        }
    }

    private var channelAvatar: some View {
        Circle()
            .fill(Color(.tertiarySystemFill))
            .frame(width: 36, height: 36)
            .overlay {
                Text(String(channelInfo.title.prefix(1)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.items) { item in
                        channelRow(item: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }

                    if !viewModel.hasReachedNewest {
                        Color.clear
                            .frame(height: 1)
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
                if viewModel.isLoadingOlder {
                    loadingOverlay
                        .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottom) {
                if viewModel.isLoadingNewer {
                    loadingOverlay
                        .padding(.bottom, 8)
                }
            }
            .onScrollPhaseChange { _, newPhase in
                isScrollActive = newPhase.isScrolling
                if newPhase.isScrolling {
                    hasLoadedSinceRest = false
                    loadOlderTask?.cancel()
                    loadOlderTask = nil
                } else {
                    scheduleTrim(at: viewportAnchorID)
                    loadOlderIfNeededAtRest()
                }
            }
            .onScrollGeometryChange(
                for: Bool.self,
                of: { geometry in
                    let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                    return visibleBottom >= geometry.contentSize.height - 24
                },
                action: { _, isNearBottom in
                    guard isNearBottom, !viewModel.hasReachedNewest else { return }
                    Task { await viewModel.loadNewer() }
                }
            )
            .task(id: initialScrollTarget) {
                await applyInitialScroll(using: proxy)
            }
        }
    }

    private func channelRow(item: FeedItem) -> some View {
        channelCard(item: item)
            .id(item.id)
    }

    private func channelCard(item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(relativeTime(for: item.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !viewModel.isRead(item) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }

                Spacer()
            }

            if let formattedText = item.formattedText, !formattedText.text.isEmpty {
                FormattedTextView(formattedText: formattedText)
            }

            if let mediaInfo = item.mediaInfo {
                MediaContentView(mediaInfo: mediaInfo)
            }

            ReactionsBarView(reactions: item.reactions)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
        guard let topAnchor = orderedVisibleIDs.first.flatMap({ resolvedItemID(for: $0) }) else { return }
        let readingAnchor = orderedVisibleIDs.isEmpty
            ? nil
            : resolvedItemID(for: orderedVisibleIDs[orderedVisibleIDs.count / 2])

        viewportAnchorID = topAnchor

        scheduleTrim(at: topAnchor)
        viewModel.scheduleMarkAsRead(currentPosition: readingAnchor ?? topAnchor)
    }

    private func orderedVisibleTargets(from visibleIDs: [FeedItemID]) -> [FeedItemID] {
        let indexByID = Dictionary(uniqueKeysWithValues: viewModel.items.enumerated().map { ($1.id, $0) })
        return visibleIDs.sorted { (indexByID[$0] ?? .max) < (indexByID[$1] ?? .max) }
    }

    private func resolvedItemID(for target: FeedItemID) -> FeedItemID? {
        viewModel.items.first(where: { $0.matches(target) })?.id
    }

    private func loadOlderIfNeededAtRest() {
        guard !hasLoadedSinceRest,
              let topAnchor = viewportAnchorID else { return }

        hasLoadedSinceRest = true
        loadOlderTask?.cancel()
        loadOlderTask = Task {
            _ = await viewModel.loadOlderIfNeeded(currentPosition: topAnchor)
            if !Task.isCancelled { loadOlderTask = nil }
        }
    }

    private func applyInitialScroll(using proxy: ScrollViewProxy) async {
        guard isContentReady,
              let target = initialScrollTarget,
              !hasAppliedInitialScroll else { return }

        hasAppliedInitialScroll = true
        viewportAnchorID = target

        await Task.yield()
        await Task.yield()

        proxy.scrollTo(
            target,
            anchor: initialMessageId == nil ? .bottom : .top
        )

        scrollPosition = ScrollPosition(
            id: target,
            anchor: initialMessageId == nil ? .bottom : .top
        )
    }
}
