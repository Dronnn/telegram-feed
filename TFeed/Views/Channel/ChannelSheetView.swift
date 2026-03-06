import SwiftUI

struct ChannelSheetView: View {
    let channelInfo: ChannelInfo
    let initialMessageId: FeedItemID?

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChannelViewModel
    @State private var scrollPosition: FeedItemID?
    @State private var isContentReady = false

    init(channelInfo: ChannelInfo, scrollTo messageId: FeedItemID? = nil) {
        self.channelInfo = channelInfo
        self.initialMessageId = messageId
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
        .task {
            await viewModel.load(aroundMessageId: initialMessageId?.messageId)
            if let target = initialMessageId,
               viewModel.items.contains(where: { $0.matches(target) }) {
                scrollPosition = target
            } else if let last = viewModel.items.last {
                scrollPosition = last.id
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
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onChange(of: scrollPosition) { _, newValue in
            guard let pos = newValue else { return }

            // Threshold-based upward loading
            Task { await viewModel.loadOlderIfNeeded(currentPosition: pos) }

            // Trim excess items above
            viewModel.trimTopIfNeeded(currentPosition: pos)

            // Mark visible messages as read
            viewModel.scheduleMarkAsRead(currentPosition: pos)

            // Load newer when near bottom
            if let idx = viewModel.items.firstIndex(where: { $0.matches(pos) }),
               idx >= viewModel.items.count - 5, !viewModel.hasReachedNewest {
                Task { await viewModel.loadNewer() }
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

    private func extraScrollTargets(for item: FeedItem) -> [FeedItemID] {
        item.representedMessageIds.compactMap { messageId in
            guard messageId != item.messageId else { return nil }
            return FeedItemID(chatId: item.chatId, messageId: messageId)
        }
    }
}
