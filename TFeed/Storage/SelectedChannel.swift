import Foundation
import SwiftData

@Model
final class SelectedChannel {
    @Attribute(.unique) var chatId: Int64
    var title: String

    init(chatId: Int64, title: String) {
        self.chatId = chatId
        self.title = title
    }
}
