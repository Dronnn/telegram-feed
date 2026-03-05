import SwiftUI

struct TdImageView: View {
    let fileId: Int
    let minithumbnail: Data?

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let minithumbnail, let blurImage = UIImage(data: minithumbnail) {
                Image(uiImage: blurImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 10)
            } else {
                Color(.tertiarySystemFill)
            }

            if isLoading && image == nil {
                ProgressView()
            }
        }
        .clipped()
        .task(id: fileId) {
            await loadImage()
        }
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
