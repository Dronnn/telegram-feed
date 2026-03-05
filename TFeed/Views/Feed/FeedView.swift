import SwiftUI
import SwiftData

struct FeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = FeedViewModel()
    @State private var scrollPosition: FeedItemID?
    @State private var showSettings = false
    @State private var selectedChannel: ChannelInfo?
    @State private var selectedMessageId: FeedItemID?

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
            let savedPosition = ScrollPositionStore.load()
            await viewModel.load(selectedIDs: appState.selectedChannelIDs)
            viewModel.startListening()
            if let savedPosition, viewModel.items.contains(where: { $0.id == savedPosition }) {
                scrollPosition = savedPosition
            }
        }
        .onDisappear {
            viewModel.stopListening()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active, let position = scrollPosition {
                ScrollPositionStore.save(position)
            }
        }
        .onChange(of: appState.selectedChannelIDs) { _, newIDs in
            Task {
                let previousPosition = scrollPosition
                let previousIndex = previousPosition.flatMap { pos in
                    viewModel.items.firstIndex(where: { $0.id == pos })
                }

                await viewModel.applyChannelChanges(newIDs: newIDs)

                if let prev = previousPosition,
                   !viewModel.items.contains(where: { $0.id == prev }),
                   !viewModel.items.isEmpty {
                    if let idx = previousIndex {
                        let clampedIdx = min(idx, viewModel.items.count - 1)
                        scrollPosition = viewModel.items[clampedIdx].id
                    } else {
                        scrollPosition = viewModel.items.last?.id
                    }
                }
            }
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
                    await viewModel.refresh(selectedIDs: appState.selectedChannelIDs)
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    private var feedContent: some View {
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
                    }, onPostLinkTap: { url in
                        if let channel = viewModel.channels[item.chatId] {
                            let messageId = parseTelegramMessageId(from: url, fallback: item.messageId)
                            selectedMessageId = FeedItemID(chatId: item.chatId, messageId: messageId)
                            selectedChannel = channel
                        }
                    })
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollPosition(id: $scrollPosition)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .refreshable {
            await viewModel.refresh(selectedIDs: appState.selectedChannelIDs)
        }
        .onChange(of: scrollPosition) { _, newValue in
            viewModel.updateScrollPosition(newValue)
            if let pos = newValue,
               let first = viewModel.items.first,
               pos == first.id {
                Task {
                    await viewModel.loadOlder()
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
                withAnimation {
                    scrollPosition = last.id
                }
                viewModel.scrolledToBottom()
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

    private func parseTelegramMessageId(from url: URL, fallback: Int64) -> Int64 {
        let components = url.pathComponents.filter { $0 != "/" }
        // t.me/channelname/12345 -> components = ["channelname", "12345"]
        guard components.count >= 2,
              let serverMessageId = Int64(components.last ?? "") else {
            return fallback
        }
        // TDLib message IDs for channels = server_message_id << 20
        let tdlibMessageId = serverMessageId << 20
        return tdlibMessageId
    }
}
