import SwiftUI
import AVKit
import AVFoundation

struct MediaContentView: View {
    let mediaInfo: MediaInfo

    @State private var showFullscreen = false

    var body: some View {
        Group {
            switch mediaInfo {
            case .photo(let info):
                photoView(info)

            case .video(let info):
                videoView(info)

            case .animation(let info):
                animationView(info)

            case .voiceNote(let info):
                AudioPlayerView(
                    fileId: info.fileId,
                    duration: info.duration,
                    title: "",
                    performer: "",
                    waveformData: info.waveform
                )

            case .audio(let info):
                AudioPlayerView(
                    fileId: info.fileId,
                    duration: info.duration,
                    title: info.title,
                    performer: info.performer,
                    waveformData: nil
                )
            }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenMediaView(mediaInfo: mediaInfo)
        }
    }

    @ViewBuilder
    private func photoView(_ info: MediaInfo.PhotoMediaInfo) -> some View {
        TdImageView(fileId: info.fileId, minithumbnail: info.minithumbnail)
            .aspectRatio(aspectRatioValue(width: info.width, height: info.height), contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture { showFullscreen = true }
    }

    @ViewBuilder
    private func videoView(_ info: MediaInfo.VideoMediaInfo) -> some View {
        VideoPlayerView(info: info)
            .aspectRatio(aspectRatioValue(width: info.width, height: info.height), contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture { showFullscreen = true }
    }

    @ViewBuilder
    private func animationView(_ info: MediaInfo.AnimationMediaInfo) -> some View {
        AnimationInlineView(info: info)
            .aspectRatio(aspectRatioValue(width: info.width, height: info.height), contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture { showFullscreen = true }
    }

    private func aspectRatioValue(width: Int, height: Int) -> CGFloat {
        guard height > 0 else { return 16.0 / 9.0 }
        let ratio = CGFloat(width) / CGFloat(height)
        // Clamp to reasonable range
        return max(0.4, min(3.0, ratio))
    }
}

// MARK: - Inline Animation (GIF)

private struct AnimationInlineView: View {
    let info: MediaInfo.AnimationMediaInfo

    @State private var player: AVPlayer?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let player {
                VideoPlayerLoopView(player: player)
            } else if let minithumbnail = info.minithumbnail, let img = UIImage(data: minithumbnail) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 10)
            } else {
                Color(.tertiarySystemFill)
            }

            if isLoading && player == nil {
                ProgressView()
            }
        }
        .clipped()
        .task {
            await loadAnimation()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func loadAnimation() async {
        if let path = await TDLibService.shared.filePath(for: info.animationFileId) {
            startPlayer(path: path)
            return
        }

        do {
            let file = try await TDLibService.shared.downloadFile(id: info.animationFileId, priority: 8)
            guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else {
                isLoading = false
                return
            }
            startPlayer(path: file.local.path)
        } catch {
            isLoading = false
        }
    }

    private func startPlayer(path: String) {
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.isMuted = true
        player = avPlayer
        isLoading = false
        avPlayer.play()

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            avPlayer.seek(to: .zero)
            avPlayer.play()
        }
    }
}

// MARK: - Looping Video Player UIViewRepresentable

private struct VideoPlayerLoopView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerUIView(player: player)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private class PlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
