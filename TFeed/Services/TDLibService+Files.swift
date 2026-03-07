import Foundation
import TDLibKit

extension TDLibService {
    func downloadFile(id: Int, priority: Int = 5) async throws -> File {
        guard let client = getClient() else { throw TDLibServiceError.clientNotInitialized }
        let stream = updateRouter.updates()

        if let existing = try? await getFile(id: id),
           existing.local.isDownloadingCompleted,
           !existing.local.path.isEmpty {
            return existing
        }

        _ = try await client.downloadFile(
            fileId: id,
            limit: 0,
            offset: 0,
            priority: priority,
            synchronous: false
        )

        if let started = try? await getFile(id: id),
           started.local.isDownloadingCompleted,
           !started.local.path.isEmpty {
            return started
        }

        for await update in stream {
            guard !Task.isCancelled else { throw CancellationError() }
            guard case .updateFile(let value) = update, value.file.id == id else { continue }
            if value.file.local.isDownloadingCompleted, !value.file.local.path.isEmpty {
                return value.file
            }
        }

        throw CancellationError()
    }

    func getFile(id: Int) async throws -> File {
        guard let client = getClient() else { throw TDLibServiceError.clientNotInitialized }
        return try await client.getFile(fileId: id)
    }

    func filePath(for fileId: Int) async -> String? {
        guard let file = try? await getFile(id: fileId) else { return nil }
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return nil }
        return file.local.path
    }
}
