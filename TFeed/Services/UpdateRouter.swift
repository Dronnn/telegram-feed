import Foundation
import TDLibKit

extension Update: @retroactive @unchecked Sendable {}

final class UpdateRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Update>.Continuation] = [:]

    func send(_ update: Update) {
        lock.withLock {
            for continuation in continuations.values {
                continuation.yield(update)
            }
        }
    }

    func updates() -> AsyncStream<Update> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.lock.withLock {
                self?.continuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    _ = self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }
}
