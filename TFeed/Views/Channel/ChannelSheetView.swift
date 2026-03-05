import SwiftUI

struct ChannelSheetView: View {
    let channelInfo: ChannelInfo
    let initialMessageId: FeedItemID?
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChannelViewModel
    @State private var scrollPosition: FeedItemID?
    @State private var pendingInitialMessageID: FeedItemID?
    @State private var requestedScrollTarget: FeedItemID?
    @State private var hasScheduledInitialPlacement = false

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
            requestedScrollTarget = nil
            hasScheduledInitialPlacement = false
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
                        channelCard(item: item)
                            .padding(.horizontal, 16)
                            .id(item.id)
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
                if let first = viewModel.items.first, pos == first.id, !viewModel.hasReachedOldest {
                    Task { await viewModel.loadOlder() }
                }
                if let last = viewModel.items.last, pos == last.id, !viewModel.hasReachedNewest {
                    Task { await viewModel.loadNewer() }
                }
            }
            .onChange(of: requestedScrollTarget) { _, target in
                guard let target else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollPosition = target
                    await Task.yield()
                    proxy.scrollTo(target, anchor: .top)
                    scrollPosition = target
                    requestedScrollTarget = nil
                }
            }
        }
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
        guard requestedScrollTarget == nil else { return }

        if let pendingInitialMessageID {
            if let target = viewModel.items.first(where: { $0.matches(pendingInitialMessageID) }) {
                self.pendingInitialMessageID = nil
                hasScheduledInitialPlacement = true
                requestScroll(to: target.id)
                return
            }

            if viewModel.isLoading {
                return
            }

            self.pendingInitialMessageID = nil
        }

        guard !hasScheduledInitialPlacement, scrollPosition == nil, let last = viewModel.items.last else { return }
        hasScheduledInitialPlacement = true
        requestScroll(to: last.id)
    }

    private func requestScroll(to target: FeedItemID) {
        guard requestedScrollTarget != target else { return }
        requestedScrollTarget = target
    }
}
