import SwiftUI

struct ChannelAvatarView: View {
    let title: String
    let avatarFileId: Int?
    var size: CGFloat = 32

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.tertiarySystemFill))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initial)
                    .font(initialFont)
                    .foregroundStyle(.secondary)
            }

            if isLoading && image == nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: avatarFileId) {
            await loadAvatar()
        }
    }

    private var initial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }

    private var initialFont: Font {
        if size >= 36 {
            return .caption.weight(.semibold)
        }
        if size >= 32 {
            return .caption.weight(.semibold)
        }
        return .caption2.weight(.semibold)
    }

    private func loadAvatar() async {
        image = nil

        guard let avatarFileId else { return }

        if let path = await TDLibService.shared.filePath(for: avatarFileId),
           let loaded = UIImage(contentsOfFile: path) {
            image = loaded
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let file = try await TDLibService.shared.downloadFile(id: avatarFileId, priority: 6)
            guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return }
            if let loaded = UIImage(contentsOfFile: file.local.path) {
                image = loaded
            }
        } catch {
            // Keep the fallback initial.
        }
    }
}
