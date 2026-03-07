import SwiftUI

struct TdImageView: View {
    let fileId: Int
    let minithumbnail: Data?
    var fallbackAspectRatio: CGFloat? = nil

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 10)
            } else {
                Color(.tertiarySystemFill)
            }

            if isLoading && image == nil {
                ProgressView()
            }
        }
        .aspectRatio(resolvedAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: fileId) {
            await loadImage()
        }
    }

    private var thumbnailImage: UIImage? {
        guard let minithumbnail else { return nil }
        return UIImage(data: minithumbnail)
    }

    private var resolvedAspectRatio: CGFloat {
        if let image, image.size.height > 0 {
            return image.size.width / image.size.height
        }

        if let thumbnailImage, thumbnailImage.size.height > 0 {
            return thumbnailImage.size.width / thumbnailImage.size.height
        }

        if let fallbackAspectRatio, fallbackAspectRatio > 0 {
            return fallbackAspectRatio
        }

        return 1
    }

    private func loadImage() async {
        // Check if already downloaded
        if let path = await TDLibService.shared.filePath(for: fileId),
           let loaded = UIImage(contentsOfFile: path) {
            image = loaded
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let file = try await TDLibService.shared.downloadFile(id: fileId, priority: 10)
            guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return }
            if let loaded = UIImage(contentsOfFile: file.local.path) {
                image = loaded
            }
        } catch {
            // Download failed — keep placeholder
        }
    }
}
