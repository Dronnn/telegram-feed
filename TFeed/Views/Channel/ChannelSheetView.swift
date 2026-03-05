import SwiftUI

struct ChannelSheetView: View {
    let channelInfo: ChannelInfo
    let initialMessageId: FeedItemID?

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChannelViewModel
    @State private var scrollPosition: FeedItemID?
    @State private var pendingInitialMessageID: FeedItemID?
    @State private var pendingScrollRequest: ChannelScrollRequest?
    @State private var didScheduleInitialPlacement = false
    @State private var isPerformingProgrammaticScroll = false

    init(channelInfo: ChannelInfo, scrollTo messageId: FeedItemID? = nil) {
        self.channelInfo = channelInfo
        self.initialMessageId = messageId
        self._viewModel = State(initialValue: ChannelViewModel(channelInfo: channelInfo))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.items.isEmpty {
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
        .task {
            pendingInitialMessageID = initialMessageId
            pendingScrollRequest = nil
            didScheduleInitialPlacement = false
            isPerformingProgrammaticScroll = false
            scrollPosition = nil
            await viewModel.load(aroundMessageId: initialMessageId?.messageId)
            restoreInitialScrollIfPossible()
        }
        .onChange(of: viewModel.items) { _, _ in
            restoreInitialScrollIfPossible()
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
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    if viewModel.isLoadingOlder {
                        ProgressView()
                            .padding()
                    }

                    ForEach(viewModel.items) { item in
                        channelRow(item: item)
                            .padding(.horizontal, 16)
                    }

                    if viewModel.isLoadingNewer {
                        ProgressView()
                            .padding()
                    } else if !viewModel.hasReachedNewest {
                        Color.clear
                            .frame(height: 1)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 12)
            }
            .scrollPosition(id: $scrollPosition)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onChange(of: scrollPosition) { _, newValue in
                guard let pos = newValue else { return }
                guard !isPerformingProgrammaticScroll else { return }

                if let first = viewModel.items.first, first.matches(pos), !viewModel.hasReachedOldest {
                    Task { await viewModel.loadOlder() }
                }
                if let last = viewModel.items.last, last.matches(pos), !viewModel.hasReachedNewest {
                    Task { await viewModel.loadNewer() }
                }
            }
            .onChange(of: pendingScrollRequest) { _, request in
                guard let request else { return }
                let anchor: UnitPoint = request.anchor == .bottom ? .bottom : .top
                Task { @MainActor in
                    isPerformingProgrammaticScroll = true
                    await Task.yield()
                    guard pendingScrollRequest == request else {
                        isPerformingProgrammaticScroll = false
                        return
                    }
                    proxy.scrollTo(request.target, anchor: anchor)
                    pendingScrollRequest = nil
                    await Task.yield()
                    isPerformingProgrammaticScroll = false
                }
            }
        }
    }

    private func channelRow(item: FeedItem) -> some View {
        channelCard(item: item)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    ForEach(extraScrollTargets(for: item), id: \.self) { target in
                        Color.clear
                            .frame(height: 1)
                            .opacity(0.001)
                            .id(target)
                    }
                }
            }
            .id(item.id)
    }

    private func channelCard(item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(relativeTime(for: item.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func restoreInitialScrollIfPossible() {
        guard pendingScrollRequest == nil, !isPerformingProgrammaticScroll else { return }

        if let pendingInitialMessageID {
            guard containsScrollableTarget(for: pendingInitialMessageID) else { return }
            didScheduleInitialPlacement = true
            requestScroll(to: pendingInitialMessageID, anchor: .top)
            return
        }

        guard !didScheduleInitialPlacement, scrollPosition == nil, let last = viewModel.items.last else { return }
        didScheduleInitialPlacement = true
        requestScroll(to: last.id, anchor: .bottom)
    }

    private func requestScroll(to target: FeedItemID, anchor: ChannelScrollRequest.Anchor) {
        pendingScrollRequest = ChannelScrollRequest(target: target, anchor: anchor)
        if pendingInitialMessageID == target {
            self.pendingInitialMessageID = nil
        }
    }

    private func containsScrollableTarget(for target: FeedItemID) -> Bool {
        viewModel.items.contains(where: { $0.matches(target) })
    }

    private func extraScrollTargets(for item: FeedItem) -> [FeedItemID] {
        item.representedMessageIds.compactMap { messageId in
            guard messageId != item.messageId else { return nil }
            return FeedItemID(chatId: item.chatId, messageId: messageId)
        }
    }
}

private struct ChannelScrollRequest: Equatable {
    enum Anchor: Equatable {
        case top
        case bottom
    }

    let target: FeedItemID
    let anchor: Anchor
}
