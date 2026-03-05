import Foundation
import TDLibKit

extension TDLibService {
    func downloadFile(id: Int, priority: Int = 5) async throws -> File {
        guard let client = getClient() else { throw TDLibServiceError.noClient }
        return try await client.downloadFile(
            fileId: id,
            limit: 0,
            offset: 0,
            priority: priority,
            synchronous: true
        )
    }

    func getFile(id: Int) async throws -> File {
        guard let client = getClient() else { throw TDLibServiceError.noClient }
        return try await client.getFile(fileId: id)
    }

    func filePath(for fileId: Int) async -> String? {
        guard let file = try? await getFile(id: fileId) else { return nil }
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return nil }
        return file.local.path
    }
}
