import Foundation

struct ChannelInfo: Identifiable, Sendable, Hashable {
    let id: Int64
    let title: String
    let avatarFileId: Int?
}
