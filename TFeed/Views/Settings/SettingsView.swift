import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var viewModel = SettingsViewModel()
    @State private var showClearCacheConfirmation = false
    @State private var showLogoutConfirmation = false
    @State private var showFaceIDInfo = false

    let channels: [Int64: ChannelInfo]

    var body: some View {
        NavigationStack {
            List {
                channelsSection
                dataSection
                securitySection
                accountSection
            }
            .listStyle(.insetGrouped)
            .searchable(text: $viewModel.searchText, prompt: "Search channels...")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            viewModel.load(channels: channels, selectedIDs: appState.selectedChannelIDs)
        }
        .onChange(of: viewModel.selectedIDs) { _, newValue in
            appState.selectedChannelIDs = newValue
        }
        .confirmationDialog("Clear Cache", isPresented: $showClearCacheConfirmation) {
            Button("Clear Local Cache", role: .destructive) {
                Task { await viewModel.clearCache() }
            }
        } message: {
            Text("This will remove cached media files. They will be re-downloaded when needed.")
        }
        .confirmationDialog("Log Out", isPresented: $showLogoutConfirmation) {
            Button("Log Out", role: .destructive) {
                Task { await viewModel.logout() }
            }
        } message: {
            Text("Are you sure you want to log out of your Telegram account?")
        }
        .alert("Require Face ID", isPresented: $showFaceIDInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Long-press the TFeed icon on your Home Screen, tap \"Require Face ID\", and choose your preference.")
        }
    }

    // MARK: - Sections

    private var channelsSection: some View {
        Section("Channels") {
            ForEach(viewModel.filteredChannels) { channel in
                channelRow(channel)
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button {
                showClearCacheConfirmation = true
            } label: {
                HStack {
                    Text("Clear Local Cache")
                        .foregroundStyle(Color(.label))
                    Spacer()
                    if viewModel.isClearing {
                        ProgressView()
                    }
                }
            }
        }
    }

    private var securitySection: some View {
        Section("Security") {
            Button {
                showFaceIDInfo = true
            } label: {
                HStack {
                    Image(systemName: "faceid")
                        .foregroundStyle(.blue)
                    Text("Require Face ID")
                        .foregroundStyle(Color(.label))
                    Spacer()
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Button {
                showLogoutConfirmation = true
            } label: {
                Text("Log Out")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Channel Row

    private func channelRow(_ channel: ChannelInfo) -> some View {
        Toggle(isOn: Binding(
            get: { viewModel.isSelected(channel) },
            set: { _ in viewModel.toggle(channel, context: modelContext) }
        )) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Text(String(channel.title.prefix(1)).uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                Text(channel.title)
            }
        }
    }
}
