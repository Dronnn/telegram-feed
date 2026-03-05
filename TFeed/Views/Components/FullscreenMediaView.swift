import SwiftUI
import AVKit

struct FullscreenMediaView: View {
    let mediaInfo: MediaInfo
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Color.black
                .opacity(max(0.3, 1.0 - abs(offset.height) / 400.0))
                .ignoresSafeArea()

            mediaContent
                .scaleEffect(scale)
                .offset(offset)
                .gesture(dragGesture)
                .gesture(magnifyGesture)

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch mediaInfo {
        case .photo(let info):
            TdImageView(fileId: info.fileId, minithumbnail: info.minithumbnail)
                .aspectRatio(info.width > 0 && info.height > 0 ? CGFloat(info.width) / CGFloat(info.height) : 1, contentMode: .fit)

        case .video(let info):
            FullscreenVideoPlayer(info: info)

        case .animation(let info):
            FullscreenAnimationPlayer(info: info)

        default:
            EmptyView()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = value.translation
                isDragging = true
            }
            .onEnded { value in
                isDragging = false
                if abs(value.translation.height) > 150 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) {
                        offset = .zero
                    }
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(0.5, min(4, value.magnification))
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.3)) {
                    scale = max(1, scale)
                }
            }
    }
}

// MARK: - Fullscreen Video

private struct FullscreenVideoPlayer: View {
    let info: MediaInfo.VideoMediaInfo

    @State private var player: AVPlayer?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(
                        info.width > 0 && info.height > 0 ? CGFloat(info.width) / CGFloat(info.height) : 16.0 / 9.0,
                        contentMode: .fit
                    )
            } else if isLoading {
                ProgressView()
                    .tint(.white)
            }
        }
        .task {
            await loadVideo()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadVideo() async {
        if let path = await TDLibService.shared.filePath(for: info.videoFileId) {
            startPlayer(path: path)
            return
        }

        do {
            let file = try await TDLibService.shared.downloadFile(id: info.videoFileId, priority: 16)
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
        let avPlayer = AVPlayer(url: URL(fileURLWithPath: path))
        player = avPlayer
        isLoading = false
        avPlayer.play()
    }
}

// MARK: - Fullscreen Animation (GIF)

private struct FullscreenAnimationPlayer: View {
    let info: MediaInfo.AnimationMediaInfo

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var observer: NSObjectProtocol?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(
                        info.width > 0 && info.height > 0 ? CGFloat(info.width) / CGFloat(info.height) : 1,
                        contentMode: .fit
                    )
            } else if isLoading {
                ProgressView()
                    .tint(.white)
            }
        }
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
            let file = try await TDLibService.shared.downloadFile(id: info.animationFileId, priority: 10)
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
