import SwiftUI

struct FeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = FeedViewModel()
    @State private var scrollPosition: FeedItemID?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Restore saved scroll position
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
            if newPhase == .background, let position = scrollPosition {
                ScrollPositionStore.save(position)
            }
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

    private var feedContent: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 12) {
                if viewModel.isLoadingMore {
                    ProgressView()
                        .padding()
                }

                ForEach(viewModel.items) { item in
                    FeedCardView(item: item)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .scrollPosition(id: $scrollPosition)
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
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}
