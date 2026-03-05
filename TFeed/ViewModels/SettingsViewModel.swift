import Foundation
import SwiftData
import TDLibKit

@MainActor
@Observable
final class SettingsViewModel {
    var allChannels: [ChannelInfo] = []
    var selectedIDs: Set<Int64> = []
    var searchText = ""
    var isClearing = false

    var filteredChannels: [ChannelInfo] {
        if searchText.isEmpty { return allChannels }
        return allChannels.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    func load(channels: [Int64: ChannelInfo], selectedIDs: Set<Int64>) {
        self.allChannels = channels.values.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        self.selectedIDs = selectedIDs
    }

    func isSelected(_ channel: ChannelInfo) -> Bool {
        selectedIDs.contains(channel.id)
    }

    func toggle(_ channel: ChannelInfo, context: ModelContext) {
        let channelId = channel.id
        if selectedIDs.contains(channelId) {
            selectedIDs.remove(channelId)
            let descriptor = FetchDescriptor<SelectedChannel>(
                predicate: #Predicate { $0.chatId == channelId }
            )
            if let existing = try? context.fetch(descriptor).first {
                context.delete(existing)
            }
        } else {
            selectedIDs.insert(channelId)
            context.insert(SelectedChannel(chatId: channelId, title: channel.title))
        }
        try? context.save()
    }

    func refreshChannels() async {
        do {
            try await TDLibService.shared.loadChats()
            let chatIds = try await TDLibService.shared.getChats()
            var newChannels: [ChannelInfo] = []
            for chatId in chatIds {
                let chat = try await TDLibService.shared.getChat(chatId: chatId)
                if case .chatTypeSupergroup = chat.type {
                    newChannels.append(ChannelInfo(
                        id: chatId,
                        title: chat.title,
                        avatarFileId: chat.photo?.small.id
                    ))
                }
            }
            allChannels = newChannels.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        } catch {
            print("[TFeed] Channel refresh error: \(error)")
        }
    }

    func clearCache() async {
        isClearing = true
        defer { isClearing = false }
        do {
            try await TDLibService.shared.optimizeStorage()
        } catch { print("[TFeed] Error: \(error)") }
    }

    func logout() async {
        do {
            try await TDLibService.shared.logOut()
        } catch { print("[TFeed] Error: \(error)") }
    }
}
