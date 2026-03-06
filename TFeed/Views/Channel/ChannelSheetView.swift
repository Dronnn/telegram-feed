import SwiftUI

struct ChannelSheetView: View {
    let channelInfo: ChannelInfo
    let initialMessageId: FeedItemID?
    var onReadStateChanged: ((Int64, Int64) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChannelViewModel
    @State private var viewportAnchorID: FeedItemID?
    @State private var isContentReady = false
    @State private var isScrollActive = false
    @State private var trimTask: Task<Void, Never>?
    @State private var loadOlderTask: Task<Void, Never>?
    @State private var visibleItemIDs: Set<FeedItemID> = []
    @State private var initialScrollTarget: (id: FeedItemID, anchor: UnitPoint)?

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
            onReadStateChanged?(channelInfo.id, viewModel.lastReadInboxMessageId)
        }
        .task {
            await viewModel.load(aroundMessageId: initialMessageId?.messageId)
            if let target = resolvedInitialScrollTarget() {
                viewportAnchorID = target
                initialScrollTarget = (id: target, anchor: .center)
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
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.items) { item in
                        channelRow(item: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .onAppear {
                                visibleItemIDs.insert(item.id)
                                handleVisibleTargets(Array(visibleItemIDs))
                                triggerLoadOlderIfNeeded()
                            }
                            .onDisappear {
                                visibleItemIDs.remove(item.id)
                            }
                    }

                    if !viewModel.hasReachedNewest {
                        Color.clear
                            .frame(height: 1)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .transaction { transaction in
                transaction.scrollContentOffsetAdjustmentBehavior = .automatic
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
            .onAppear {
                if let target = initialScrollTarget {
                    initialScrollTarget = nil
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
            }
            .onScrollPhaseChange { _, newPhase in
                isScrollActive = newPhase.isScrolling
                if newPhase.isScrolling {
                    loadOlderTask?.cancel()
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

    private func resolvedInitialScrollTarget() -> FeedItemID? {
        if let initialMessageId {
            return viewModel.items.first(where: { $0.matches(initialMessageId) })?.id
        }
        return viewModel.items.last?.id
    }

    private func orderedVisibleTargets(from visibleIDs: [FeedItemID]) -> [FeedItemID] {
        let indexByID = Dictionary(uniqueKeysWithValues: viewModel.items.enumerated().map { ($1.id, $0) })
        return visibleIDs.sorted { (indexByID[$0] ?? .max) < (indexByID[$1] ?? .max) }
    }

    private func resolvedItemID(for target: FeedItemID) -> FeedItemID? {
        viewModel.items.first(where: { $0.matches(target) })?.id
    }

    private func triggerLoadOlderIfNeeded() {
        guard initialScrollTarget == nil,
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
        guard initialScrollTarget == nil,
              let topAnchor = viewportAnchorID else { return }

        loadOlderTask?.cancel()
        loadOlderTask = Task {
            defer { loadOlderTask = nil }
            _ = await viewModel.loadOlderIfNeeded(currentPosition: topAnchor)
        }
    }
}
