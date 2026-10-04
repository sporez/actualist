import Foundation
import Synchronization
import Testing
@testable import Actualist

/// Chunked, bounded response reading shared by sync, budget downloads and
/// SimpleFIN. Each test owns a unique stub host, so the suite can run in parallel.
struct LimitedResponseReaderTests {
    private let chunk = 16 * 1_024

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func request(_ script: ChunkedStubURLProtocol.Script) -> (URLRequest, ChunkedStubURLProtocol.Recorder) {
        let host = "reader-\(UUID().uuidString.lowercased()).example"
        let recorder = ChunkedStubURLProtocol.register(host: host, script: script)
        return (URLRequest(url: URL(string: "https://\(host)/body")!), recorder)
    }

    @Test func overLimitBodyThrowsWithoutDeliveringBeyondLimitPlusSlack() async throws {
        let limit = 16 * chunk
        let (request, recorder) = request(.init(chunkSize: chunk, chunkCount: nil, declaresLength: false))
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let received = Mutex(0)

        await #expect(throws: LimitedResponseReader.ReadError.limitExceeded) {
            _ = try await LimitedResponseReader.stream(
                for: request,
                session: session,
                onResponse: { _ in .init(maximumBytes: UInt64(limit)) },
                onChunk: { piece in received.withLock { $0 += piece.count } }
            )
        }
        await recorder.stopped.wait()
        #expect(received.withLock { $0 } <= limit)
        #expect(recorder.deliveredBytes <= limit + 8 * chunk)
    }

    @Test func bodyExactlyAtLimitSucceeds() async throws {
        let limit = 8 * chunk
        let (request, _) = request(.init(chunkSize: chunk, chunkCount: 8, declaresLength: false))
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let (data, response) = try await LimitedResponseReader.data(
            for: request,
            session: session,
            maximumBytes: limit
        )
        #expect(data.count == limit)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func oneByteOverLimitThrows() async throws {
        let limit = 8 * chunk - 1
        let (request, _) = request(.init(chunkSize: chunk, chunkCount: 8, declaresLength: false))
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        await #expect(throws: LimitedResponseReader.ReadError.limitExceeded) {
            _ = try await LimitedResponseReader.data(for: request, session: session, maximumBytes: limit)
        }
    }

    @Test func declaredLengthOverLimitThrowsBeforeReadingTheBody() async throws {
        let limit = 4 * chunk
        let (request, recorder) = request(.init(chunkSize: chunk, chunkCount: 64, declaresLength: true))
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        await #expect(throws: LimitedResponseReader.ReadError.limitExceeded) {
            _ = try await LimitedResponseReader.data(for: request, session: session, maximumBytes: limit)
        }
        await recorder.stopped.wait()
        #expect(recorder.deliveredBytes <= 8 * chunk)
    }

    @Test func cancellationStopsTheRead() async throws {
        let (request, recorder) = request(.init(chunkSize: chunk, chunkCount: nil, declaresLength: false))
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let task = Task {
            try await LimitedResponseReader.data(for: request, session: session, maximumBytes: 1 << 30)
        }
        await recorder.firstChunk.wait()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected the cancelled read to throw")
        } catch {
            #expect(error.isCancellation)
        }
        await recorder.stopped.wait()
    }

    @Test func truncatingPlanStopsQuietlyAtTheLimit() async throws {
        let (request, _) = request(.init(chunkSize: chunk, chunkCount: nil, declaresLength: false))
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let received = Mutex(0)

        _ = try await LimitedResponseReader.stream(
            for: request,
            session: session,
            onResponse: { _ in .init(maximumBytes: UInt64(2 * chunk), truncatesAtLimit: true) },
            onChunk: { piece in received.withLock { $0 += piece.count } }
        )
        #expect(received.withLock { $0 } == 2 * chunk)
    }

    // MARK: - Client wiring

    private func limits(syncResponse: Int) -> LocalFirstResourceLimits {
        LocalFirstResourceLimits(
            maximumCompressedBudgetBytes: 1_024,
            maximumExpandedBudgetBytes: 1_024,
            maximumArchiveEntryBytes: 1_024,
            maximumArchiveEntryCount: 10,
            maximumArchivePathDepth: 4,
            minimumFreeDiskReserveBytes: 0,
            maximumSyncResponseBytes: syncResponse
        )
    }

    @Test func oversizedSyncReplyThrowsTheTypedCatchUpError() async throws {
        let host = "sync-\(UUID().uuidString.lowercased()).example"
        ChunkedStubURLProtocol.register(
            host: host,
            script: .init(chunkSize: chunk, chunkCount: 4, declaresLength: false)
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://\(host)")!,
            session: session,
            resourceLimits: limits(syncResponse: 2 * chunk)
        )

        do {
            _ = try await client.sync(data: Data(), token: "token")
            Issue.record("expected sync to throw")
        } catch let error as ActualAPIError {
            guard case .syncCatchUpTooLarge = error else {
                Issue.record("expected syncCatchUpTooLarge, got \(error)")
                return
            }
        } catch {
            Issue.record("expected syncCatchUpTooLarge, got \(error)")
        }
    }

    @Test func syncReplyAtTheLimitStillSucceeds() async throws {
        let host = "sync-\(UUID().uuidString.lowercased()).example"
        ChunkedStubURLProtocol.register(
            host: host,
            script: .init(chunkSize: chunk, chunkCount: 2, declaresLength: true)
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://\(host)")!,
            session: session,
            resourceLimits: limits(syncResponse: 2 * chunk)
        )

        let reply = try await client.sync(data: Data(), token: "token")
        #expect(reply.count == 2 * chunk)
    }

    @Test func oversizedNonSyncReplyKeepsTheGenericLimitError() async throws {
        let host = "login-\(UUID().uuidString.lowercased()).example"
        ChunkedStubURLProtocol.register(
            host: host,
            script: .init(chunkSize: chunk, chunkCount: 4, declaresLength: false)
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://\(host)")!,
            session: session,
            resourceLimits: limits(syncResponse: 2 * chunk)
        )

        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            _ = try await client.loginMethods()
        }
    }
}

/// Delivers paced fixed-size chunks per host and records delivery and stop.
final class ChunkedStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var chunkSize: Int
        /// `nil` keeps sending until the loader is stopped.
        var chunkCount: Int?
        var declaresLength: Bool
    }

    final class Recorder: Sendable {
        private let delivered = Mutex(0)
        let firstChunk = TestLatch()
        let stopped = TestLatch()
        var deliveredBytes: Int { delivered.withLock { $0 } }
        func record(_ count: Int) {
            delivered.withLock { $0 += count }
            firstChunk.trip()
        }
    }

    private static let registry = Mutex<[String: (Script, Recorder)]>([:])

    @discardableResult
    static func register(host: String, script: Script) -> Recorder {
        let recorder = Recorder()
        registry.withLock { $0[host] = (script, recorder) }
        return recorder
    }

    private let state = Mutex(false)
    private let queue = DispatchQueue(label: "ChunkedStubURLProtocol")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let (script, recorder) = Self.registry.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if script.declaresLength, let count = script.chunkCount {
            headers["Content-Length"] = String(count * script.chunkSize)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(script: script, recorder: recorder, sent: 0)
    }

    private func send(script: Script, recorder: Recorder, sent: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
            if state.withLock({ $0 }) { return }
            if let count = script.chunkCount, sent >= count {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            recorder.record(script.chunkSize)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: script.chunkSize))
            send(script: script, recorder: recorder, sent: sent + 1)
        }
    }

    override func stopLoading() {
        state.withLock { $0 = true }
        if let host = request.url?.host,
           let recorder = Self.registry.withLock({ $0[host]?.1 }) {
            recorder.stopped.trip()
        }
    }
}
