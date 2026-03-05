import Foundation
import TDLibKit

extension MessageContent {
    func extractMediaInfo() -> MediaInfo? {
        switch self {
        case .messagePhoto(let msg):
            guard let largest = msg.photo.sizes.last else { return nil }
            return .photo(.init(
                fileId: largest.photo.id,
                width: largest.width,
                height: largest.height,
                minithumbnail: msg.photo.minithumbnail?.data
            ))

        case .messageVideo(let msg):
            return .video(.init(
                thumbnailFileId: msg.video.thumbnail?.file.id,
                videoFileId: msg.video.video.id,
                duration: msg.video.duration,
                width: msg.video.width,
                height: msg.video.height,
                minithumbnail: msg.video.minithumbnail?.data
            ))

        case .messageAnimation(let msg):
            return .animation(.init(
                thumbnailFileId: msg.animation.thumbnail?.file.id,
                animationFileId: msg.animation.animation.id,
                width: msg.animation.width,
                height: msg.animation.height,
                minithumbnail: msg.animation.minithumbnail?.data
            ))

        case .messageVoiceNote(let msg):
            return .voiceNote(.init(
                fileId: msg.voiceNote.voice.id,
                duration: msg.voiceNote.duration,
                waveform: msg.voiceNote.waveform
            ))

        case .messageAudio(let msg):
            return .audio(.init(
                fileId: msg.audio.audio.id,
                duration: msg.audio.duration,
                title: msg.audio.title,
                performer: msg.audio.performer
            ))

        default:
            return nil
        }
    }
}
