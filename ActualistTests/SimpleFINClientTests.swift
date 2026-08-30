import Foundation
import Testing
@testable import Actualist

/// Phase 1 tests for the SimpleFIN server transport: route support
/// classification, response decoding, and error-code → durable status
/// mapping. The URLProtocol stub shares mutable statics, so the suite runs
/// serialized.
@Suite(.serialized)
struct SimpleFINClientTests {
    private func makeClient(
        statusCode: Int,
        body: String,
        failConnect: Bool = false
    ) -> ActualServerSimpleFINClient {
        let configuration = URLSessionConfiguration.ephemeral
        if failConnect {
            configuration.protocolClasses = [UnreachableSimpleFINURLProtocol.self]
        } else {
            configuration.protocolClasses = [SimpleFINStubURLProtocol.self]
            SimpleFINStubURLProtocol.statusCode = statusCode
            SimpleFINStubURLProtocol.body = body
        }
        return ActualServerSimpleFINClient(
            baseURL: URL(string: "https://sync.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    // MARK: - Status

    @Test func configuredStatusReturnsConfigured() async throws {
        // Actual's server wraps the answer in {status, data}.
        let client = makeClient(statusCode: 200, body: #"{"status": "ok", "data": {"configured": true}}"#)
        let support = try await client.simpleFINStatus(token: "token")
        #expect(support == .configured)
    }

    @Test func flatStatusShapeRemainsSupported() async throws {
        let client = makeClient(statusCode: 200, body: #"{"configured": true}"#)
        let support = try await client.simpleFINStatus(token: "token")
        #expect(support == .configured)
    }

    @Test func unconfiguredStatusReturnsNotConfigured() async throws {
        let client = makeClient(statusCode: 200, body: #"{"status": "ok", "data": {"configured": false}}"#)
        let support = try await client.simpleFINStatus(token: "token")
        #expect(support == .notConfigured)
    }

    @Test func statusRoute404MeansUnsupportedNotAnError() async throws {
        let client = makeClient(statusCode: 404, body: "not found")
        let support = try await client.simpleFINStatus(token: "token")
        #expect(support == .unsupported)
    }

    @Test func statusRoute405MeansUnsupported() async throws {
        let client = makeClient(statusCode: 405, body: "")
        let support = try await client.simpleFINStatus(token: "token")
        #expect(support == .unsupported)
    }

    @Test func statusRoute501MeansUnsupported() async throws {
        let client = makeClient(statusCode: 501, body: "")
        let support = try await client.simpleFINStatus(token: "token")
        #expect(support == .unsupported)
    }

    @Test func unreachableServerThrowsInsteadOfReportingUnsupported() async throws {
        let client = makeClient(statusCode: 0, body: "", failConnect: true)
        await #expect(throws: ActualAPIError.self) {
            _ = try await client.simpleFINStatus(token: "token")
        }
    }

    @Test func otherHTTPStatusesThrow() async throws {
        let client = makeClient(statusCode: 500, body: "boom")
        await #expect(throws: ActualAPIError.self) {
            _ = try await client.simpleFINStatus(token: "token")
        }
    }

    // MARK: - Accounts

    @Test func accountsDecodesWrappedAccountList() async throws {
        let body = """
        {"status": "ok", "data": {"accounts": [{
            "account_id": "acct_1",
            "name": "Checking",
            "balance": 1234.56,
            "currency": "USD",
            "institution": "First Bank",
            "orgDomain": "firstbank.example",
            "orgId": "org_9"
        }]}}
        """
        let client = makeClient(statusCode: 200, body: body)
        let accounts = try await client.simpleFINAccounts(token: "token")
        #expect(accounts?.count == 1)
        #expect(accounts?.first?.accountID == "acct_1")
        #expect(accounts?.first?.name == "Checking")
        #expect(accounts?.first?.balance == "1234.56")
        #expect(accounts?.first?.currency == "USD")
        #expect(accounts?.first?.institution == "First Bank")
        #expect(accounts?.first?.orgDomain == "firstbank.example")
        #expect(accounts?.first?.orgID == "org_9")
    }

    @Test func accountsRoute404ReturnsNil() async throws {
        let client = makeClient(statusCode: 404, body: "")
        let accounts = try await client.simpleFINAccounts(token: "token")
        #expect(accounts == nil)
    }

    @Test func accountsBalanceDecodesStringDecimal() async throws {
        let body = """
        {"data": {"accounts": [{"account_id": "a", "name": "n", "balance": "88.10"}]}}
        """
        let client = makeClient(statusCode: 200, body: body)
        let accounts = try await client.simpleFINAccounts(token: "token")
        #expect(accounts?.first?.balance == "88.10")
    }

    // MARK: - Transactions

    @Test func transactionsRequestSendsArraysAlways() async throws {
        let client = makeClient(statusCode: 200, body: "{}")
        _ = try await client.simpleFINTransactions(
            token: "token",
            accountIDs: ["acct_1"],
            startDates: ["2026-06-01"]
        )
        let payload = try #require(SimpleFINStubURLProtocol.lastRequestBody)
        let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(json["accountId"] as? [String] == ["acct_1"])
        #expect(json["startDate"] as? [String] == ["2026-06-01"])
    }

    @Test func transactionsDecodesServerEnvelopePayload() async throws {
        // Actual's server nests the account-keyed map under {status, data}.
        let body = """
        {
          "status": "ok",
          "data": {
            "acct_1": {
              "transactions": {"all": [
                  {"id": "t1", "date": 1709253000, "amount": "-12.34",
                   "payee_name": "Coffee Shop", "booked": true}
              ]},
              "startingBalance": 500
            },
            "errors": {"acct_2": [{"error_type": "SimplefinError",
                                    "error_code": "TIMED_OUT"}]}
          }
        }
        """
        let response = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(body.utf8)
        )
        #expect(response.downloads["acct_1"]?.transactions.count == 1)
        #expect(response.downloads["acct_1"]?.startingBalance == 500)
        #expect(response.downloads["acct_2"]?.errorCode == "TIMED_OUT")
    }

    @Test func transactionsDecodesAccountKeyedPayload() async throws {
        let body = """
        {
          "acct_1": {
            "transactions": {"all": [
                {"id": "t1", "date": 1709253000, "amount": "-12.34",
                 "payee_name": "Coffee Shop", "notes": "latte", "booked": true},
                {"id": "t2", "posted": 1709166600, "amount": "100.00",
                 "payeeName": "Employer", "booked": false}
            ]},
            "startingBalance": 500
          },
          "acct_2": {
            "transactions": {"all": []}
          }
        }
        """
        let response = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(body.utf8)
        )
        #expect(response.downloads.count == 2)
        #expect(response.downloads["acct_1"]?.transactions.count == 2)
        #expect(response.downloads["acct_1"]?.startingBalance == 500)
        #expect(response.downloads["acct_1"]?.hasError == false)
        #expect(response.downloads["acct_2"]?.transactions.isEmpty == true)

        let first = try #require(response.downloads["acct_1"]?.transactions.first)
        #expect(first.id == "t1")
        #expect(first.dateUnixSeconds == 1_709_253_000)
        #expect(first.amount == "-12.34")
        #expect(first.payeeName == "Coffee Shop")
        #expect(first.notes == "latte")
        #expect(first.booked == true)

        let second = try #require(response.downloads["acct_1"]?.transactions.dropFirst().first)
        #expect(second.dateUnixSeconds == 1_709_166_600)
        #expect(second.payeeName == "Employer")
        #expect(second.booked == false)
    }

    @Test func transactionsNullAccountEntryIsAbsentNotAnError() async throws {
        let body = #"{"acct_1": null, "acct_2": {"transactions": {"all": []}}}"#
        let response = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(body.utf8)
        )
        #expect(response.downloads["acct_1"] == nil)
        #expect(response.downloads["acct_2"] != nil)
        #expect(response.hasWholeRequestError == false)
    }

    @Test func transactionsPerAccountErrorsAreAttachedToThatAccount() async throws {
        let body = """
        {
          "acct_1": {"transactions": {"all": []}},
          "errors": {"acct_2": [{"error_type": "SimplefinError",
                                  "error_code": "INVALID_ACCESS_TOKEN"}]}
        }
        """
        let response = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(body.utf8)
        )
        #expect(response.downloads["acct_1"]?.hasError == false)
        #expect(response.downloads["acct_2"]?.errorCode == "INVALID_ACCESS_TOKEN")
        #expect(response.downloads["acct_2"]?.errorType == "SimplefinError")
    }

    @Test func transactionsWholeRequestErrorIsSurfaced() async throws {
        let body = """
        {"error_type": "SimplefinError", "error_code": "INVALID_ACCESS_TOKEN"}
        """
        let response = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(body.utf8)
        )
        #expect(response.downloads.isEmpty)
        #expect(response.errorCode == "INVALID_ACCESS_TOKEN")
        #expect(response.errorType == "SimplefinError")
        #expect(response.hasWholeRequestError == true)
    }

    @Test func transactionsErrorsOnlyEntriesGetEmptyDownloads() async throws {
        let body = """
        {"errors": {"acct_1": [{"error_type": "SimplefinError",
                                 "error_code": "TIMED_OUT"}]}}
        """
        let response = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(body.utf8)
        )
        #expect(response.downloads["acct_1"]?.transactions.isEmpty == true)
        #expect(response.downloads["acct_1"]?.errorCode == "TIMED_OUT")
    }

    @Test func transactionsNonJSONThrowsDecoding() throws {
        #expect(throws: ActualAPIError.self) {
            _ = try ActualServerSimpleFINClient.decodeTransactionsResponse(
                from: Data("[]".utf8)
            )
        }
    }

    // MARK: - Error code → durable status

    @Test func errorCodeMapsToDurableStatus() {
        #expect(ActualBankSyncDurableStatus.from(errorCode: nil) == .ok)
        #expect(ActualBankSyncDurableStatus.from(errorCode: "TIMED_OUT") == .timedOut)
        #expect(ActualBankSyncDurableStatus.from(errorCode: "ACCOUNT_MISSING") == .accountMissing)
        #expect(ActualBankSyncDurableStatus.from(errorCode: "RATE_LIMIT_EXCEEDED") == .rateLimitExceeded)
        #expect(ActualBankSyncDurableStatus.from(errorCode: "INVALID_ACCESS_TOKEN") == .reauthRequired)
        #expect(ActualBankSyncDurableStatus.from(errorCode: "SOMETHING_ELSE") == .failed)
    }
}

// MARK: - Stub URLProtocol

private final class SimpleFINStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            SimpleFINStubURLProtocol.lastRequestBody = Self.read(stream: stream)
        } else {
            SimpleFINStubURLProtocol.lastRequestBody = request.httpBody
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class UnreachableSimpleFINURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.cannotConnectToHost)
        )
    }

    override func stopLoading() {}
}
