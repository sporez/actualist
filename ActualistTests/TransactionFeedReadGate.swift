import Foundation
import Testing
@testable import Actualist

@MainActor
final class TransactionFeedReadGate {
    private var predicate: ((TransactionFeedCacheKey, String?, Int?, Int) -> Bool)?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isSuspended = false

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
        isSuspended = true
        await withCheckedContinuation { continuation = $0 }
        isSuspended = false
        continuation = nil
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilSuspended() async {
        for _ in 0..<10_000 {
            if isSuspended { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the transaction-feed read gate")
    }
}
