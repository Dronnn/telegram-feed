import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let info: MediaInfo.VideoMediaInfo

    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var videoPath: String?
    @State private var isDownloading = false

    var body: some View {
        ZStack {
            if isPlaying, let player {
                VideoPlayer(player: player)
            } else {
                thumbnailView
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            isPlaying = false
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            if let thumbnailFileId = info.thumbnailFileId {
                TdImageView(fileId: thumbnailFileId, minithumbnail: info.minithumbnail)
            } else if let minithumbnail = info.minithumbnail, let img = UIImage(data: minithumbnail) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 10)
            } else {
                Color(.tertiarySystemFill)
            }

            Button {
                Task { await playVideo() }
            } label: {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 56, height: 56)
                    .overlay {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Image(systemName: "play.fill")
                                .font(.title2)
                                .foregroundStyle(.primary)
                        }
                    }
            }
            .buttonStyle(.plain)

            // Duration badge
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(formatDuration(info.duration))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(8)
                }
            }
        }
        .clipped()
    }

    private func playVideo() async {
        if let videoPath {
            startPlayback(path: videoPath)
            return
        }

        // Check if already downloaded
        if let path = await TDLibService.shared.filePath(for: info.videoFileId) {
            videoPath = path
            startPlayback(path: path)
            return
        }

        isDownloading = true
        defer { isDownloading = false }

        do {
            let file = try await TDLibService.shared.downloadFile(id: info.videoFileId, priority: 16)
            guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return }
            videoPath = file.local.path
            startPlayback(path: file.local.path)
        } catch {
            // Download failed
        }
    }

    private func startPlayback(path: String) {
        let avPlayer = AVPlayer(url: URL(fileURLWithPath: path))
        player = avPlayer
        isPlaying = true
        avPlayer.play()
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
