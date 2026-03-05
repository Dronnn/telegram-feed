import SwiftUI

struct FeedView: View {
    @Environment(AppState.self) private var appState
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
            await viewModel.load(selectedIDs: appState.selectedChannelIDs)
            viewModel.startListening()
        }
        .onDisappear {
            viewModel.stopListening()
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
            if let pos = newValue,
               let first = viewModel.items.first,
               pos == first.id {
                Task {
                    await viewModel.loadOlder()
                }
            }
        }
    }
}
