import Foundation
import TDLibKit

extension Update: @retroactive @unchecked Sendable {}

final class UpdateRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Update>.Continuation] = [:]

    func send(_ update: Update) {
        let currentContinuations = lock.withLock {
            Array(continuations)
        }

        guard !currentContinuations.isEmpty else { return }

        var terminatedIDs: [UUID] = []
        for (id, continuation) in currentContinuations {
            if case .terminated = continuation.yield(update) {
                terminatedIDs.append(id)
            }
        }

        guard !terminatedIDs.isEmpty else { return }

        lock.withLock {
            for id in terminatedIDs {
                _ = continuations.removeValue(forKey: id)
            }
        }
    }

    func updates() -> AsyncStream<Update> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    _ = self?.continuations.removeValue(forKey: id)
                }
            }
            self?.lock.withLock {
                self?.continuations[id] = continuation
            }
        }
    }
}
