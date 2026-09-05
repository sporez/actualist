import Foundation
import Testing

/// A single cancellable sleep that advances only when the test releases it.
final class ManualTestDelay: Sendable {
    private let requests = AsyncStream<Duration>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        requests.continuation.yield(duration)
        requests.continuation.finish()
        for await _ in release.stream { break }
        try Task.checkCancellation()
    }

    func waitUntilSleeping() async throws -> Duration {
        var iterator = requests.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    func resume() {
        release.continuation.yield(())
        release.continuation.finish()
    }
}
