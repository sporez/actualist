import Foundation
import Synchronization

/// Reads an HTTP response body under a byte limit, delivered in the chunks
/// URLSession hands over rather than one byte at a time. Shared by sync
/// responses, budget downloads and SimpleFIN bridge responses.
///
/// Uses a per-task `URLSessionDataDelegate` on a plain `dataTask` (iOS 15+), so
/// an oversized body is cancelled at the transport as soon as the limit is
/// crossed, and task cancellation cancels the transfer.
enum LimitedResponseReader {
    enum ReadError: Error, Equatable {
        /// The declared or received body is larger than the caller's limit.
        case limitExceeded
    }

    /// How much of the body to read once the response head has arrived.
    struct BodyPlan: Sendable {
        var maximumBytes: UInt64
        /// `true` stops quietly at the limit instead of throwing `limitExceeded`.
        var truncatesAtLimit = false
    }

    /// Reads the whole body into memory. `onResponse` may throw to abandon the
    /// request before any body is read (for example a refused redirect).
    static func data(
        for request: URLRequest,
        session: URLSession,
        redirects: CustomHTTPHeaderRedirectDelegate? = nil,
        maximumBytes: Int,
        onResponse: @escaping @Sendable (URLResponse) throws -> Void = { _ in }
    ) async throws -> (Data, URLResponse) {
        let collected = ChunkBox()
        let response = try await stream(
            for: request,
            session: session,
            redirects: redirects,
            onResponse: { response in
                try onResponse(response)
                return BodyPlan(maximumBytes: UInt64(max(0, maximumBytes)))
            },
            onChunk: { collected.append($0) }
        )
        return (collected.data, response)
    }

    /// Streams the body to `onChunk`. A declared length above the plan is
    /// refused before any body is read. `onChunk` runs on the session's serial
    /// delegate queue and may throw to abort the transfer.
    static func stream(
        for request: URLRequest,
        session: URLSession,
        redirects: CustomHTTPHeaderRedirectDelegate? = nil,
        onResponse: @escaping @Sendable (URLResponse) throws -> BodyPlan,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws -> URLResponse {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        let collector = ChunkCollector(redirects: redirects, onResponse: onResponse, onChunk: onChunk)
        task.delegate = collector
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class ChunkCollector: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<URLResponse, any Error>?
        var response: URLResponse?
        var plan = LimitedResponseReader.BodyPlan(maximumBytes: 0)
        var count: UInt64 = 0
        var failure: (any Error)?
        var truncated = false
    }

    private let state = Mutex(State())
    private let redirects: CustomHTTPHeaderRedirectDelegate?
    private let onResponse: @Sendable (URLResponse) throws -> LimitedResponseReader.BodyPlan
    private let onChunk: @Sendable (Data) throws -> Void

    init(
        redirects: CustomHTTPHeaderRedirectDelegate?,
        onResponse: @escaping @Sendable (URLResponse) throws -> LimitedResponseReader.BodyPlan,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) {
        self.redirects = redirects
        self.onResponse = onResponse
        self.onChunk = onChunk
    }

    func begin(_ continuation: CheckedContinuation<URLResponse, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    private func fail(_ error: any Error) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirects else {
            completionHandler(request)
            return
        }
        redirects.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let plan = try onResponse(response)
            if !plan.truncatesAtLimit, response.expectedContentLength > Int64(clamping: plan.maximumBytes) {
                throw LimitedResponseReader.ReadError.limitExceeded
            }
            state.withLock {
                $0.response = response
                $0.plan = plan
            }
            completionHandler(.allow)
        } catch {
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (plan, count, alreadyStopped) = state.withLock { ($0.plan, $0.count, $0.failure != nil || $0.truncated) }
        guard !alreadyStopped else { return }
        let remaining = plan.maximumBytes - min(count, plan.maximumBytes)
        var chunk = data
        if UInt64(data.count) > remaining {
            guard plan.truncatesAtLimit else {
                fail(LimitedResponseReader.ReadError.limitExceeded)
                dataTask.cancel()
                return
            }
            chunk = data.prefix(Int(remaining))
            state.withLock { $0.truncated = true }
        }
        do {
            if !chunk.isEmpty { try onChunk(chunk) }
        } catch {
            fail(error)
            dataTask.cancel()
            return
        }
        let reachedTruncation = state.withLock { state -> Bool in
            state.count += UInt64(chunk.count)
            if state.plan.truncatesAtLimit, state.count >= state.plan.maximumBytes { state.truncated = true }
            return state.truncated
        }
        if reachedTruncation { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let outcome = state.withLock { state -> (CheckedContinuation<URLResponse, any Error>?, Result<URLResponse, any Error>) in
            let continuation = state.continuation
            state.continuation = nil
            if let failure = state.failure { return (continuation, .failure(failure)) }
            if let error, !state.truncated {
                return (continuation, .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
            }
            guard let response = state.response else {
                return (continuation, .failure(URLError(.badServerResponse)))
            }
            return (continuation, .success(response))
        }
        outcome.0?.resume(with: outcome.1)
    }
}

final class ChunkBox: Sendable {
    private let storage = Mutex(Data())

    func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    var data: Data {
        storage.withLock { $0 }
    }
}
