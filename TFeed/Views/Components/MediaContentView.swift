import SwiftUI
import AVKit
import AVFoundation

struct MediaContentView: View {
    let mediaInfo: MediaInfo

    @State private var showFullscreen = false

    private let maxInlineMediaHeight: CGFloat = 320
    private let minInlineMediaHeight: CGFloat = 180

    var body: some View {
        Group {
            switch mediaInfo {
            case .photo(let info):
                photoView(info, allowsFullscreenTap: true)

            case .video(let info):
                videoView(info, allowsFullscreenTap: true)

            case .animation(let info):
                animationView(info, allowsFullscreenTap: true)

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

            case .album(let items):
                albumView(items)
            }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenMediaView(mediaInfo: mediaInfo)
        }
    }

    @ViewBuilder
    private func photoView(_ info: MediaInfo.PhotoMediaInfo, allowsFullscreenTap: Bool) -> some View {
        TdImageView(fileId: info.fileId, minithumbnail: info.minithumbnail)
            .aspectRatio(aspectRatioValue(width: info.width, height: info.height), contentMode: .fit)
            .frame(maxHeight: inlineMediaHeight(width: info.width, height: info.height))
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture {
                guard allowsFullscreenTap else { return }
                showFullscreen = true
            }
    }

    @ViewBuilder
    private func videoView(_ info: MediaInfo.VideoMediaInfo, allowsFullscreenTap: Bool) -> some View {
        VideoPlayerView(info: info)
            .aspectRatio(aspectRatioValue(width: info.width, height: info.height), contentMode: .fit)
            .frame(maxHeight: inlineMediaHeight(width: info.width, height: info.height))
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture {
                guard allowsFullscreenTap else { return }
                showFullscreen = true
            }
    }

    @ViewBuilder
    private func animationView(_ info: MediaInfo.AnimationMediaInfo, allowsFullscreenTap: Bool) -> some View {
        AnimationInlineView(info: info)
            .aspectRatio(aspectRatioValue(width: info.width, height: info.height), contentMode: .fit)
            .frame(maxHeight: inlineMediaHeight(width: info.width, height: info.height))
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .onTapGesture {
                guard allowsFullscreenTap else { return }
                showFullscreen = true
            }
    }

    @ViewBuilder
    private func albumView(_ items: [MediaInfo]) -> some View {
        let previewItems = Array(items.prefix(4))

        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ], spacing: 6) {
            ForEach(Array(previewItems.enumerated()), id: \.offset) { index, item in
                ZStack(alignment: .center) {
                    albumThumbnail(item)

                    if index == previewItems.count - 1, items.count > previewItems.count {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.black.opacity(0.45))
                        Text("+\(items.count - previewItems.count)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFullscreen = true }
    }

    @ViewBuilder
    private func albumThumbnail(_ mediaInfo: MediaInfo) -> some View {
        switch mediaInfo {
        case .photo(let info):
            photoView(info, allowsFullscreenTap: false)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipped()

        case .video(let info):
            videoView(info, allowsFullscreenTap: false)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipped()

        case .animation(let info):
            animationView(info, allowsFullscreenTap: false)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipped()

        default:
            Color(.tertiarySystemFill)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
        }
    }

    private func aspectRatioValue(width: Int, height: Int) -> CGFloat {
        guard height > 0 else { return 16.0 / 9.0 }
        let ratio = CGFloat(width) / CGFloat(height)
        // Clamp to reasonable range
        return max(0.4, min(3.0, ratio))
    }

    private func inlineMediaHeight(width: Int, height: Int) -> CGFloat {
        guard width > 0, height > 0 else { return 240 }
        let ratio = CGFloat(width) / CGFloat(height)
        if ratio < 0.7 {
            return maxInlineMediaHeight
        }
        if ratio > 1.8 {
            return minInlineMediaHeight
        }
        return 260
    }
}

// MARK: - Inline Animation (GIF)

private struct AnimationInlineView: View {
    let info: MediaInfo.AnimationMediaInfo

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var observer: NSObjectProtocol?

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
            if let observer { NotificationCenter.default.removeObserver(observer) }
            player = nil
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

        observer = NotificationCenter.default.addObserver(
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
