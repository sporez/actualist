import Foundation
import Testing
@testable import Actualist

@MainActor
final class TransactionFeedReadGate {
    private var predicate: ((TransactionFeedCacheKey, String?, Int?, Int) -> Bool)?
    private var continuation: CheckedContinuation<Void, Never>?
    private let suspended = TestLatch()

    func holdNextRead(
        where predicate: @escaping (TransactionFeedCacheKey, String?, Int?, Int) -> Bool
    ) {
        self.predicate = predicate
    }

    func pauseIfRequested(
        key: TransactionFeedCacheKey,
        query: String?,
        limit: Int?,
        offset: Int
    ) async {
        guard let predicate, predicate(key, query, limit, offset) else { return }
        self.predicate = nil
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            suspended.trip()
        }
        continuation = nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilSuspended() async {
        await suspended.wait()
    }
}
