import SwiftUI

struct ChannelSheetView: View {
    let channelInfo: ChannelInfo
    let initialMessageId: FeedItemID?
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChannelViewModel
    @State private var scrollPosition: FeedItemID?

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
            await viewModel.load(aroundMessageId: initialMessageId?.messageId)
            if let initialMessageId,
               viewModel.items.contains(where: { $0.id == initialMessageId }) {
                scrollPosition = initialMessageId
            } else if let last = viewModel.items.last {
                scrollPosition = last.id
            }
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
                    channelCard(item: item)
                        .padding(.horizontal, 16)
                }

                if viewModel.isLoadingNewer {
                    ProgressView()
                        .padding()
                }
            }
            .padding(.vertical, 12)
        }
        .scrollPosition(id: $scrollPosition)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onChange(of: scrollPosition) { _, newValue in
            guard let pos = newValue else { return }
            if let first = viewModel.items.first, pos == first.id {
                Task { await viewModel.loadOlder() }
            }
            if let last = viewModel.items.last, pos == last.id, !viewModel.hasReachedNewest {
                Task { await viewModel.loadNewer() }
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
}
