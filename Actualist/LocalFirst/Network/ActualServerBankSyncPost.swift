import Foundation

/// The request shape every bank-sync route on an Actual server shares
/// (`/simplefin/*`, `/enablebanking/*`): a JSON POST with the sync token,
/// Actual's 60-second client timeout (loot-core `post(..., 60000)`), a capped
/// response body, and 404 / 405 / 501 read as "this server has no such route"
/// (`nil`) rather than as an error.
struct ActualServerBankSyncPost: Sendable {
    let requests: ActualServerRequestBuilder
    let session: URLSession

    /// `fileID` is sent as `X-ACTUAL-FILE-ID` when present. `limitError` is
    /// thrown when the body is larger than the cap, so each provider keeps
    /// its own copy. The body is encoded by the caller, on its own actor.
    func post(
        path: String,
        fileID: String?,
        token: String,
        jsonBody: Data,
        limitError: any Error
    ) async throws -> Data? {
        let request = try requests.makeRequest(
            path: path,
            method: "POST",
            token: token,
            fileID: fileID,
            headers: ["Accept": "application/json"],
            timeout: 60,
            body: jsonBody,
            contentType: "application/json"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await LimitedResponseReader.data(
                for: request,
                session: session,
                redirects: requests.redirectDelegate,
                maximumBytes: SimpleFINBridgeClient.maximumResponseBytes
            )
        } catch LimitedResponseReader.ReadError.limitExceeded {
            throw limitError
        } catch where error.isCancellation {
            throw CancellationError()
        } catch let error as ActualAPIError {
            throw error
        } catch let error as URLError {
            throw ActualAPIError.transport(error.code)
        } catch {
            throw ActualAPIError.transport(nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }
        if requests.redirectDelegate.refuses(httpResponse) { throw ActualAPIError.redirectRefused }
        let statusCode = httpResponse.statusCode
        // A server without these routes is "cannot sync", not an error.
        if statusCode == 404 || statusCode == 405 || statusCode == 501 {
            return nil
        }
        guard (200..<300).contains(statusCode) else {
            throw ActualServerSyncClient.apiError(statusCode: statusCode, data: data)
        }
        if let error = ActualServerSyncClient.structuredAPIError(from: data) { throw error }
        return data
    }
}
