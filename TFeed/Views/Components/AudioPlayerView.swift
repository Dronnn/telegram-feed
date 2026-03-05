import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let fileId: Int
    let duration: Int
    let title: String
    let performer: String
    let waveformData: Data?

    @State private var isPlaying = false
    @State private var player: AVAudioPlayer?
    @State private var progress: Double = 0
    @State private var isDownloading = false
    @State private var filePath: String?
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            // Play/pause button
            Button {
                Task { await togglePlayback() }
            } label: {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 40, height: 40)
                    .overlay {
                        if isDownloading {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.callout)
                                .foregroundStyle(.primary)
                        }
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                // Title/performer for audio, waveform for voice
                if !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if !performer.isEmpty {
                        Text(performer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    waveformView
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 3)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * progress), height: 3)
                    }
                }
                .frame(height: 3)
            }

            Text(formatDuration(isPlaying ? currentTime : duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onDisappear {
            stopPlayback()
        }
    }

    @ViewBuilder
    private var waveformView: some View {
        if let waveformData, !waveformData.isEmpty {
            HStack(spacing: 2) {
                let bars = decodeWaveform(waveformData, count: 32)
                ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(Double(index) / Double(bars.count) < progress ? Color.accentColor : Color(.tertiarySystemFill))
                        .frame(width: 2, height: max(2, CGFloat(value) * 16))
                }
            }
            .frame(height: 16)
        } else {
            Text("Voice message")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var currentTime: Int {
        guard let player else { return duration }
        return Int(player.currentTime)
    }

    private func togglePlayback() async {
        if isPlaying {
            pausePlayback()
            return
        }

        if let player, !isPlaying {
            player.play()
            isPlaying = true
            startTimer()
            return
        }

        // Need to download first
        if filePath == nil {
            if let path = await TDLibService.shared.filePath(for: fileId) {
                filePath = path
            } else {
                isDownloading = true
                defer { isDownloading = false }
                do {
                    let file = try await TDLibService.shared.downloadFile(id: fileId, priority: 10)
                    guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return }
                    filePath = file.local.path
                } catch {
                    return
                }
            }
        }

        guard let filePath else { return }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: filePath))
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            player = audioPlayer
            isPlaying = true
            startTimer()
        } catch {
            // Playback failed
        }
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let player, player.isPlaying else {
                    if let player, !player.isPlaying, player.currentTime >= player.duration - 0.1 {
                        stopPlayback()
                    }
                    return
                }
                let dur = player.duration
                guard dur > 0 else { return }
                progress = player.currentTime / dur
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func decodeWaveform(_ data: Data, count: Int) -> [Float] {
        // TDLib waveform: 5-bit packed values
        let bytes = [UInt8](data)
        var bits: [Float] = []
        var bitPos = 0
        while bitPos + 5 <= bytes.count * 8 {
            let byteIndex = bitPos / 8
            let bitOffset = bitPos % 8
            var value: UInt8
            if bitOffset + 5 <= 8 {
                value = (bytes[byteIndex] >> bitOffset) & 0x1F
            } else {
                let lo = bytes[byteIndex] >> bitOffset
                let hi = byteIndex + 1 < bytes.count ? bytes[byteIndex + 1] : 0
                value = (lo | (hi << (8 - bitOffset))) & 0x1F
            }
            bits.append(Float(value) / 31.0)
            bitPos += 5
        }

        guard !bits.isEmpty else { return Array(repeating: 0.1, count: count) }

        // Resample to desired count
        var result: [Float] = []
        let step = Float(bits.count) / Float(count)
        for i in 0..<count {
            let index = Int(Float(i) * step)
            result.append(bits[min(index, bits.count - 1)])
        }
        return result
    }
}
