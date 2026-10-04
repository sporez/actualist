import Foundation
import Security
import Testing
@testable import Actualist

/// Phase 5 tests (device-claim fallback): pure setup-token / access-key
/// parsing, the claim HTTP behavior, bridge response decoding, and the
/// `makeBankSyncProvider` resolution order. The suite stays serialized;
/// each test owns its own StubHTTPEndpoint.
@Suite(.serialized)
struct SimpleFINBridgeClientTests {
    private let endpoint = StubHTTPEndpoint()
    private static let accessURLBody = "https://user:secret@bridge.example/user"

    private func httpsURLString(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    // MARK: - Setup token decoding (pure)

    @Test func setupTokenDecodesToClaimURL() throws {
        let token = httpsURLString("https://bridge.example/auth/link")
        let url = try SimpleFINBridgeCredentials.claimURL(fromSetupToken: token)
        #expect(url.absoluteString == "https://bridge.example/auth/link")
    }

    @Test func setupTokenAcceptsURLSafeBase64AndMissingPadding() throws {
        // "+/" → "-_", padding stripped.
        let standard = Data("https://bridge.example/auth/??!!".utf8).base64EncodedString()
        let urlSafe = standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = try SimpleFINBridgeCredentials.claimURL(fromSetupToken: urlSafe)
        #expect(url.absoluteString == "https://bridge.example/auth/??!!")
    }

    @Test func setupTokenRefusesJunk() {
        #expect(throws: SimpleFINBridgeError.invalidSetupToken) {
            try SimpleFINBridgeCredentials.claimURL(fromSetupToken: "not a token")
        }
    }

    @Test func setupTokenRefusesNonHTTPS() {
        #expect(throws: SimpleFINBridgeError.insecureURL) {
            try SimpleFINBridgeCredentials.claimURL(fromSetupToken: httpsURLString("http://bridge.example/auth/link"))
        }
    }

    // MARK: - Access-key parsing (pure, hand-rolled)

    @Test func accessKeyParsesAtSignInPassword() throws {
        let credentials = try SimpleFINBridgeCredentials.accessCredentials(
            fromClaimBody: "https://user:p@ss@bridge.example/user"
        )
        #expect(credentials.username == "user")
        #expect(credentials.password == "p@ss")
    }

    @Test func accessKeyParsesColonInPassword() throws {
        let credentials = try SimpleFINBridgeCredentials.accessCredentials(
            fromClaimBody: "https://user:a:b:c@bridge.example/user"
        )
        #expect(credentials.username == "user")
        #expect(credentials.password == "a:b:c")
    }

    @Test func accessKeyRefusesNonHTTPSBody() {
        #expect(throws: SimpleFINBridgeError.insecureURL) {
            try SimpleFINBridgeCredentials.accessCredentials(
                fromClaimBody: "http://user:pass@bridge.example/user"
            )
        }
    }

    @Test func accessKeyRefusesMissingCredentialParts() {
        #expect(throws: SimpleFINBridgeError.invalidAccessURL) {
            try SimpleFINBridgeCredentials.accessCredentials(
                fromClaimBody: "https://bridge.example/user"
            )
        }
        #expect(throws: SimpleFINBridgeError.invalidAccessURL) {
            try SimpleFINBridgeCredentials.accessCredentials(
                fromClaimBody: "https://noseparator@bridge.example/user"
            )
        }
    }

    @Test func baseURLStripsCredentials() throws {
        let url = try SimpleFINBridgeCredentials.baseURL(fromClaimBody: Self.accessURLBody)
        #expect(url.absoluteString == "https://bridge.example/user")
    }

    @Test func basicAuthorizationEncodesUserAndPassword() {
        let header = SimpleFINBridgeCredentials.basicAuthorization(username: "user", password: "p@ss:word")
        #expect(header == "Basic \(Data("user:p@ss:word".utf8).base64EncodedString())")
    }

    // MARK: - Claim (network)

    private func makeClaimClient(statusCode: Int, body: String) -> URLSession {
        endpoint.respond(statusCode: statusCode, body: body)
        return endpoint.makeSession()
    }

    @Test func claimReturnsParsedCredentialsAndBaseURL() async throws {
        let session = makeClaimClient(statusCode: 200, body: Self.accessURLBody)
        let claimed = try await SimpleFINBridgeClient.claim(
            setupToken: httpsURLString("https://bridge.example/auth/link"),
            session: session
        )
        #expect(claimed.baseURL.absoluteString == "https://bridge.example/user")
        #expect(claimed.username == "user")
        #expect(claimed.password == "secret")
    }

    @Test func claim403MeansAlreadyClaimed() async throws {
        let session = makeClaimClient(statusCode: 403, body: "")
        await #expect(throws: SimpleFINBridgeError.alreadyClaimed) {
            try await SimpleFINBridgeClient.claim(
                setupToken: httpsURLString("https://bridge.example/auth/link"),
                session: session
            )
        }
    }

    @Test func claim200WithForbiddenBodyMeansAlreadyClaimed() async throws {
        let session = makeClaimClient(statusCode: 200, body: "Forbidden")
        await #expect(throws: SimpleFINBridgeError.alreadyClaimed) {
            try await SimpleFINBridgeClient.claim(
                setupToken: httpsURLString("https://bridge.example/auth/link"),
                session: session
            )
        }
    }

    @Test func claim500SurfacesUnexpectedStatus() async throws {
        let session = makeClaimClient(statusCode: 500, body: "boom")
        await #expect(throws: SimpleFINBridgeError.unexpectedStatus(500)) {
            try await SimpleFINBridgeClient.claim(
                setupToken: httpsURLString("https://bridge.example/auth/link"),
                session: session
            )
        }
    }

    // MARK: - Bridge response decoding (network)

    private func makeBridgeClient(body: String) -> SimpleFINBridgeClient {
        endpoint.respond(statusCode: 200, body: body)
        return SimpleFINBridgeClient(
            baseURL: URL(string: "https://bridge.example/user")!,
            username: "user",
            password: "secret",
            session: endpoint.makeSession()
        )
    }

    @Test func remoteAccountsDecodeBalanceAndOrg() async throws {
        let client = makeBridgeClient(body: """
        {"errors": [], "errlist": [{"code": "notice", "msg": "Provider notice", "account_id": "acct_1"}], "accounts": [{
            "id": "acct_1",
            "name": "Checking",
            "balance": "1234.56",
            "currency": "USD",
            "institution": "First Bank",
            "org": {"domain": "firstbank.example", "id": "org_9", "name": "First Bank"}
        }]}
        """)
        let accounts = try await client.remoteAccounts()
        #expect(accounts.count == 1)
        #expect(accounts.first?.accountID == "acct_1")
        #expect(accounts.first?.balance == "1234.56")
        #expect(accounts.first?.orgName == "First Bank")
        #expect(accounts.first?.orgDomain == "firstbank.example")
        #expect(accounts.first?.orgID == "org_9")
        let query = try #require(endpoint.lastRequest?.url?.query)
        #expect(query.contains("balances-only=1"))
        #expect(!query.contains("pending=1"))
    }

    @Test func transactionsMergePostedAndPendingAndKeyByAccount() async throws {
        let client = makeBridgeClient(body: """
        {"accounts": [{
            "id": "acct_1",
            "name": "Checking",
            "balance": "50.00",
            "currency": "USD",
            "transactions": [
                {"id": "tx_1", "posted": 1709253000, "amount": "-12.50", "description": "Coffee",
                 "extra": {"notes": "morning"}}
            ],
            "pending": [
                {"id": "tx_2", "posted": 0, "transacted_at": 1709339400,
                 "amount": "-3.25", "description": "Gas", "pending": true},
                {"id": "tx_1", "posted": 1709253000, "amount": "-12.50",
                 "description": "Duplicate Coffee", "pending": true}
            ]
        }]}
        """)
        let response = try await client.transactions(accountIDs: ["acct_1"], startDates: ["2024-02-01"])
        let download = response.downloads["acct_1"]
        #expect(download?.errorCode == nil)
        #expect(download?.transactions.count == 2)
        #expect(download?.transactions.first?.id == "tx_1")
        #expect(download?.transactions.first?.notes == "morning")
        #expect(download?.transactions.first?.payeeName == "Coffee")
        #expect(download?.transactions.first?.currency == "USD")
        #expect(download?.transactions.first?.rawFields["notes"]?.scalarString == "morning")
        #expect(download?.transactions.first?.rawFields["description"]?.scalarString == "Coffee")
        #expect(download?.transactions.last?.booked == false)
        #expect(download?.transactions.last?.dateUnixSeconds == 1_709_339_400)
        #expect(download?.currentBalance == SimpleFINBalanceAmount(
            amount: "50.00",
            currency: "USD"
        ))
    }

    @Test func batchedTransactionsUseEarliestRequestDateAndFilterEachAccountWindow() async throws {
        let client = makeBridgeClient(body: """
        {"accounts": [
            {
                "id": "older-window",
                "name": "Older",
                "transactions": [
                    {"id": "old-jan", "posted": 1705320000, "amount": "-1.00", "description": "January"}
                ]
            },
            {
                "id": "newer-window",
                "name": "Newer",
                "transactions": [
                    {"id": "new-jan", "posted": 1705320000, "amount": "-2.00", "description": "Too old"},
                    {"id": "new-mar", "posted": 1709294400, "amount": "-3.00", "description": "March"}
                ]
            }
        ]}
        """)

        let response = try await client.transactions(
            accountIDs: ["older-window", "newer-window"],
            startDates: ["2024-01-01", "2024-02-01"]
        )

        #expect(response.downloads["older-window"]?.transactions.map(\.id) == ["old-jan"])
        #expect(response.downloads["newer-window"]?.transactions.map(\.id) == ["new-mar"])
        let query = try #require(endpoint.lastRequest?.url?.query)
        #expect(query.contains("start-date=\(SimpleFINBridgeClient.unixSeconds(fromDay: "2024-01-01"))"))
    }

    @Test func transactionsRequestSendsBasicAuthAndDateQuery() async throws {
        let client = makeBridgeClient(body: #"{"accounts": []}"#)
        _ = try await client.transactions(accountIDs: ["acct_1"], startDates: ["2024-02-01"])
        let request = try #require(endpoint.lastRequest)
        #expect(request.url?.path.hasSuffix("/accounts") == true)
        let query = request.url?.query ?? ""
        #expect(query.contains("start-date="))
        #expect(query.contains("end-date="))
        #expect(query.contains("pending=1"))
        #expect(request.value(forHTTPHeaderField: "Authorization")?
            .hasPrefix("Basic ") == true)
    }

    @Test func missingAccountBecomesAccountMissingDownload() async throws {
        let client = makeBridgeClient(body: #"{"accounts": []}"#)
        let response = try await client.transactions(accountIDs: ["gone"], startDates: ["2024-02-01"])
        #expect(response.downloads["gone"]?.errorCode == "ACCOUNT_MISSING")
    }

    @Test func http402And403MapToPaymentAndRevoked() async throws {
        do {
            let client = makeBridgeClient(body: "{}")
            endpoint.respond(statusCode: 402, body: "{}")
            _ = try await client.remoteAccounts()
            Issue.record("expected paymentRequired")
        } catch let error as SimpleFINBridgeError {
            #expect(error == .paymentRequired)
        }
        do {
            let client = makeBridgeClient(body: "{}")
            endpoint.respond(statusCode: 403, body: "{}")
            _ = try await client.remoteAccounts()
            Issue.record("expected accessRevoked")
        } catch let error as SimpleFINBridgeError {
            #expect(error == .accessRevoked)
        }
    }

    private static func makeChunkedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func oversizedSimpleFINBridgeReplyThrowsBankSyncCopy() async throws {
        let host = "bridge-\(UUID().uuidString.lowercased()).example"
        let cap = SimpleFINBridgeClient.maximumResponseBytes
        ChunkedStubURLProtocol.register(
            host: host,
            script: .init(chunkSize: 1_024 * 1_024, chunkCount: cap / (1_024 * 1_024) + 1, declaresLength: false)
        )
        let session = Self.makeChunkedSession()
        defer { session.invalidateAndCancel() }
        let client = SimpleFINBridgeClient(
            baseURL: URL(string: "https://\(host)/user")!,
            username: "user",
            password: "secret",
            session: session
        )

        await #expect(throws: SimpleFINBridgeError.responseTooLarge) {
            _ = try await client.remoteAccounts()
        }
        #expect(
            SimpleFINBridgeError.responseTooLarge.errorDescription
                == "SimpleFIN returned more data than Actualist can safely read, so nothing was imported."
        )
    }
}

// MARK: - Provider resolution (store-level)

/// `makeBankSyncProvider` ordering: server configured wins; unreachable
/// server + device key falls back to the bridge; no key rethrows.
extension LocalFirstActualStoreTests {
    private func saveDeviceKey(_ bundle: OpenedWritableStoreBundle) throws {
        try bundle.keychain.saveSimpleFINAccessURL("https://user:secret@bridge.example/user")
    }

    @Test func serverConfiguredWinsOverStoredDeviceKey() async throws {
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(support: .configured)
        )
        try saveDeviceKey(bundle)
        let provider = try await bundle.store.bankSyncProvider(budgetID: "group-1")
        #expect(!provider.isDevice)
    }

    @Test func serverWithoutSimpleFINUsesDeviceKey() async throws {
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(support: .notConfigured)
        )
        try saveDeviceKey(bundle)
        let provider = try await bundle.store.bankSyncProvider(budgetID: "group-1")
        #expect(provider.isDevice)
    }

    @Test func serverWithoutSimpleFINAndNoDeviceKeyRefusesLocally() async throws {
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(support: .unsupported)
        )
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.notConfigured) {
            try await bundle.store.bankSyncProvider(budgetID: "group-1")
        }
    }

    @Test func unreachableServerWithDeviceKeyFallsBackToBridge() async throws {
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(failure: ActualAPIError.transport(URLError.Code.cannotFindHost))
        )
        try saveDeviceKey(bundle)
        let provider = try await bundle.store.bankSyncProvider(budgetID: "group-1")
        #expect(provider.isDevice)
    }

    @Test func unreachableServerWithoutDeviceKeyThrows() async throws {
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(failure: ActualAPIError.transport(URLError.Code.cannotFindHost))
        )
        await #expect(throws: ActualAPIError.self) {
            try await bundle.store.bankSyncProvider(budgetID: "group-1")
        }
    }

    @Test func unavailableDeviceKeyDoesNotBecomeUnconfiguredOrPersistProviderFailure() async throws {
        let backend = FakeKeychainBackend()
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(support: .notConfigured), keychainBackend: backend
        )
        try saveDeviceKey(bundle)
        backend.copyFailureAccountStatuses[bundle.keychain.simplefinAccessKeyAccount] = errSecAuthFailed
        #expect(throws: KeychainReadError.unavailable(errSecAuthFailed)) {
            try bundle.store.hasBankSyncDeviceKey()
        }
        await #expect(throws: KeychainReadError.unavailable(errSecAuthFailed)) {
            try await bundle.store.bankSyncProvider(budgetID: "group-1")
        }
        let rows = try await bundle.store.bankSyncAccountRows(budgetID: "group-1")
        #expect(rows.allSatisfy { $0.durableStatus == nil })
        backend.copyFailureAccountStatuses = [:]
        #expect(try bundle.store.hasBankSyncDeviceKey())
        #expect(try await bundle.store.bankSyncProvider(budgetID: "group-1").isDevice)
    }

    @Test func transportFailureDoesNotMaskUnavailableDeviceKeyAsOffline() async throws {
        let backend = FakeKeychainBackend()
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(failure: .transport(.cannotFindHost)), keychainBackend: backend
        )
        try saveDeviceKey(bundle)
        backend.copyFailureAccountStatuses[bundle.keychain.simplefinAccessKeyAccount] = errSecInteractionNotAllowed
        await #expect(throws: KeychainReadError.unavailable(errSecInteractionNotAllowed)) {
            try await bundle.store.bankSyncProvider(budgetID: "group-1")
        }
    }

    @Test func forgetRemovesDeviceKeyOnlyAndKeysSurviveBudgetSwitch() async throws {
        let bundle = try await makeBankSyncStore(
            transport: StubSimpleFINTransport(support: .notConfigured)
        )
        try saveDeviceKey(bundle)
        #expect(try bundle.store.hasBankSyncDeviceKey())
        // Erase must wipe the device key with the rest of local data.
        #expect(try bundle.store.keychain.readSimpleFINAccessURL() != nil)
        try bundle.store.forgetBankSyncDeviceKey()
        #expect(try !bundle.store.hasBankSyncDeviceKey())
        #expect(try bundle.store.keychain.readSimpleFINAccessURL() == nil)
    }
}
