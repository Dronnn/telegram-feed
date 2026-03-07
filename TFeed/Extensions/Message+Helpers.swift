import Foundation
import TDLibKit

extension MessageContent {
    var shouldAppearInFeed: Bool {
        switch self {
        case .messagePoll:
            return false
        default:
            return true
        }
    }

    func extractFormattedText() -> FormattedText? {
        switch self {
        case .messageText(let messageText):
            return messageText.text
        case .messagePhoto(let photo):
            return photo.caption.text.isEmpty ? nil : photo.caption
        case .messageVideo(let video):
            return video.caption.text.isEmpty ? nil : video.caption
        case .messageAnimation(let animation):
            return animation.caption.text.isEmpty ? nil : animation.caption
        case .messageVoiceNote(let voice):
            return voice.caption.text.isEmpty ? nil : voice.caption
        case .messageAudio(let audio):
            return audio.caption.text.isEmpty ? nil : audio.caption
        case .messageDocument(let doc):
            return doc.caption.text.isEmpty ? nil : doc.caption
        default:
            return nil
        }
    }
}

extension MessageInteractionInfo {
    func extractReactions() -> [FeedItem.Reaction] {
        guard let reactions = reactions?.reactions else { return [] }
        return reactions.compactMap { reaction in
            switch reaction.type {
            case .reactionTypeEmoji(let emoji):
                return FeedItem.Reaction(emoji: emoji.emoji, count: reaction.totalCount)
            default:
                return nil
            }
        }
    }
}

private let sharedDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

private let exactTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .current
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func relativeTime(for timestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let interval = Date.now.timeIntervalSince(date)

    if interval < 60 { return "now" }
    if interval < 3600 { return "\(Int(interval / 60))m" }
    if interval < 86400 { return "\(Int(interval / 3600))h" }
    if interval < 604800 { return "\(Int(interval / 86400))d" }

    return sharedDateFormatter.string(from: date)
}

func exactTimestamp(for timestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    return exactTimestampFormatter.string(from: date)
}
