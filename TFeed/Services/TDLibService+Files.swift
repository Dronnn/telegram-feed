import Foundation
import TDLibKit

extension TDLibService {
    func downloadFile(id: Int, priority: Int = 5) async throws -> File {
        guard let client = getClient() else { throw TDLibServiceError.clientNotInitialized }

        if let existing = try? await getFile(id: id),
           existing.local.isDownloadingCompleted,
           !existing.local.path.isEmpty {
            return existing
        }

        do {
            return try await withThrowingTaskGroup(of: File.self) { group in
                group.addTask {
                    try await client.downloadFile(
                        fileId: id,
                        limit: 0,
                        offset: 0,
                        priority: priority,
                        synchronous: true
                    )
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw TDLibServiceError.fileDownloadTimedOut
                }

                guard let file = try await group.next() else {
                    throw TDLibServiceError.fileDownloadFailed
                }
                group.cancelAll()

                if file.local.isDownloadingCompleted, !file.local.path.isEmpty {
                    return file
                }

                if let refreshed = try? await getFile(id: id),
                   refreshed.local.isDownloadingCompleted,
                   !refreshed.local.path.isEmpty {
                    return refreshed
                }

                throw TDLibServiceError.fileDownloadFailed
            }
        } catch {
            _ = try? await client.cancelDownloadFile(fileId: id, onlyIfPending: false)
            throw error
        }
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
