import Foundation

enum MediaInfo: Sendable, Equatable {
    case photo(PhotoMediaInfo)
    case video(VideoMediaInfo)
    case animation(AnimationMediaInfo)
    case voiceNote(VoiceNoteMediaInfo)
    case audio(AudioMediaInfo)
    indirect case album([MediaInfo])

    struct PhotoMediaInfo: Sendable, Equatable {
        let fileId: Int
        let width: Int
        let height: Int
        let minithumbnail: Data?
    }

    struct VideoMediaInfo: Sendable, Equatable {
        let thumbnailFileId: Int?
        let videoFileId: Int
        let duration: Int
        let width: Int
        let height: Int
        let minithumbnail: Data?
    }

    struct AnimationMediaInfo: Sendable, Equatable {
        let thumbnailFileId: Int?
        let animationFileId: Int
        let width: Int
        let height: Int
        let minithumbnail: Data?
    }

    struct VoiceNoteMediaInfo: Sendable, Equatable {
        let fileId: Int
        let duration: Int
        let waveform: Data
    }

    struct AudioMediaInfo: Sendable, Equatable {
        let fileId: Int
        let duration: Int
        let title: String
        let performer: String
    }

    var aspectRatio: CGFloat? {
        switch self {
        case .photo(let info):
            guard info.height > 0 else { return nil }
            return CGFloat(info.width) / CGFloat(info.height)
        case .video(let info):
            guard info.height > 0 else { return nil }
            return CGFloat(info.width) / CGFloat(info.height)
        case .animation(let info):
            guard info.height > 0 else { return nil }
            return CGFloat(info.width) / CGFloat(info.height)
        case .voiceNote, .audio:
            return nil
        case .album(let items):
            return items.first?.aspectRatio
        }
    }
}
