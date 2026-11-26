import Foundation

/// Enable Banking through the open budget's Actual server: whether the server
/// is set up (`POST /enablebanking/status`), and downloads, one
/// `POST /enablebanking/transactions` per account, in order, as Actual's web
/// app syncs every non-SimpleFIN account (loot-core `accounts-bank-sync`).
/// The store owns it; the Bank Sync planner turns the downloads into plans.
@MainActor
final class EnableBankingWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore
    /// The client for the current endpoint and custom headers, so repeated
    /// runs reuse one URL session.
    private var cachedClient: (key: String, client: ActualServerEnableBankingClient)?

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    // MARK: - Server support

    /// The last answer for the open server and budget, for the screen's
    /// optimistic first draw. Downloads never rely on it.
    func cachedSupport() -> SimpleFINServerSupport? {
        guard let serverURL = store.openedServerURLString, let fileID = store.openedCloudFileID else {
            return nil
        }
        return store.bankSyncSessionCache.enableBankingSupport(for: serverURL, fileID: fileID)
    }

    /// Asks the server whether it has Enable Banking credentials and
    /// remembers the answer for the open session.
    func support(budgetID: String) async throws -> SimpleFINServerSupport {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let endpoint = try store.bankSync.bankSyncServerEndpoint(budgetID: budgetID)
        let support = try await transport(for: endpoint).status(token: endpoint.token)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if let serverURL = store.openedServerURLString, let fileID = store.openedCloudFileID {
            store.bankSyncSessionCache.rememberEnableBankingSupport(support, for: serverURL, fileID: fileID)
        }
        return support
    }

    // MARK: - Downloads

    /// One linked account's request.
    struct AccountRequest: Equatable, Sendable {
        let accountID: String
        let remoteAccountID: String
        let startDate: String
        /// The linked bank's `banks.name`, sent as `aspspName`.
        let aspspName: String?
    }

    /// Error codes for an account whose request itself failed. The server
    /// sends its own codes for provider failures; these cover the request
    /// never getting an answer. `TIMED_OUT` stores `timed-out`, the others
    /// `not-configured` and `failed` (`ActualBankSyncDurableStatus.from`).
    enum RequestFailureCode {
        static let timedOut = "TIMED_OUT"
        /// The server has no Enable Banking routes (404 / 405 / 501).
        static let routesMissing = "NOT_CONFIGURED"
        static let failed = "REQUEST_FAILED"
    }

    /// Downloads every account in `requests` order. Cancellation, the budget
    /// session and each account's download generation are checked before and
    /// after every request, so a budget switch or a newer download stops the
    /// loop. One account's failure becomes that account's download error and
    /// the loop goes on; failures that are not about one account (a
    /// cancelled run, an expired sign-in, a refused or local-only address)
    /// end the run. Enable Banking credentials are server-wide, so once the
    /// server says it has none, the remaining accounts get the same answer
    /// without another request.
    ///
    /// With a `deadline` (background runs), no request starts after it and a
    /// request still running at it is abandoned: those accounts get no
    /// download and are left for the next run, with nothing stored.
    func downloads(
        _ requests: [AccountRequest],
        budgetID: String,
        database: BudgetDatabase,
        sessionGeneration: Int,
        generations: [String: UUID],
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> [String: SimpleFINAccountDownload] {
        guard !requests.isEmpty else { return [:] }
        let endpoint = try store.bankSync.bankSyncServerEndpoint(budgetID: budgetID)
        let transport = try transport(for: endpoint)
        var downloads: [String: SimpleFINAccountDownload] = [:]
        var serverHasNoEnableBanking: SimpleFINAccountDownload?
        accounts: for request in requests {
            try requireCurrent(request, database: database, budgetID: budgetID,
                sessionGeneration: sessionGeneration, generations: generations)
            if let serverHasNoEnableBanking {
                downloads[request.accountID] = serverHasNoEnableBanking
                continue
            }
            let download: SimpleFINAccountDownload
            do {
                let answer = try await Self.request(
                    request, token: endpoint.token, transport: transport, deadline: deadline
                )
                download = answer ?? Self.failedDownload(code: RequestFailureCode.routesMissing)
            } catch is DeadlineReached {
                break accounts
            } catch {
                guard let code = Self.accountFailureCode(error) else { throw error }
                download = Self.failedDownload(code: code)
            }
            try requireCurrent(request, database: database, budgetID: budgetID,
                sessionGeneration: sessionGeneration, generations: generations)
            if ActualBankSyncDurableStatus.from(errorCode: download.errorCode) == .notConfigured {
                serverHasNoEnableBanking = download
            }
            downloads[request.accountID] = download
        }
        return downloads
    }

    private struct DeadlineReached: Error {}

    private static func request(
        _ request: AccountRequest,
        token: String,
        transport: any EnableBankingServerTransport,
        deadline: ContinuousClock.Instant?
    ) async throws -> SimpleFINAccountDownload? {
        let send: @MainActor @Sendable () async throws -> SimpleFINAccountDownload? = {
            try await transport.transactions(
                token: token,
                accountID: request.remoteAccountID,
                startDate: request.startDate,
                aspspName: request.aspspName
            )
        }
        guard let deadline else { return try await send() }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw DeadlineReached() }
        return try await withDeadline(remaining, timeoutError: DeadlineReached(), operation: send)
    }

    private func requireCurrent(
        _ request: AccountRequest,
        database: BudgetDatabase,
        budgetID: String,
        sessionGeneration: Int,
        generations: [String: UUID]
    ) throws {
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: sessionGeneration)
        guard let generation = generations[request.accountID],
              store.bankSyncGenerationByAccount[request.accountID] == generation else {
            throw BankSyncWorkflows.BankSyncStoreError.staleGeneration
        }
    }

    private static func failedDownload(code: String) -> SimpleFINAccountDownload {
        SimpleFINAccountDownload(transactions: [], startingBalance: nil, errorType: nil, errorCode: code)
    }

    /// The download error for a request that failed for this account only,
    /// or `nil` when the failure ends the whole run.
    private static func accountFailureCode(_ error: Error) -> String? {
        guard !error.isCancellation, let error = error as? ActualAPIError, !error.isAuthenticationFailure else {
            return nil
        }
        switch error {
        case .transport(.timedOut):
            return RequestFailureCode.timedOut
        case .transport, .httpStatus, .decoding, .invalidResponse, .serverRejected:
            return RequestFailureCode.failed
        case .invalidURL, .redirectRefused, .localNetworkDenied, .unsupportedAuthenticationMethod,
             .syncRejected, .syncCatchUpTooLarge:
            return nil
        }
    }

    private func transport(for endpoint: BankSyncWorkflows.BankSyncServerEndpoint) throws -> any EnableBankingServerTransport {
        #if DEBUG
        if let factory = store.testSeams?.enableBankingTransportFactory {
            return factory(endpoint.url)
        }
        #endif
        let key = "\(endpoint.role.rawValue):\(endpoint.url.absoluteString):\(store.customHeadersRevision)"
        if let cachedClient, cachedClient.key == key { return cachedClient.client }
        let fields = try store.keychain.readCustomHTTPHeaders().fields(for: endpoint.role, url: endpoint.url)
        let client = ActualServerEnableBankingClient(
            baseURL: endpoint.url,
            customHeaders: fields,
            session: store.transportSession
        )
        cachedClient = (key, client)
        return client
    }
}
