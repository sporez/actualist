import Foundation
import GRDB
import Testing
@testable import Actualist

/// Enable Banking downloads through the Bank Sync planner: provider routing,
/// one request per account after the SimpleFIN batch, per-account failures,
/// and the Enable Banking rules of the download preparation. Downloads are
/// Actual's own server responses from the `EnableBankingServer` fixture.
@MainActor
struct EnableBankingPlanningTests {
    private let support = LocalFirstActualStoreTests()
    private typealias StubSimpleFINTransport = LocalFirstActualStoreTests.StubSimpleFINTransport
    private typealias OpenedWritableStoreBundle = LocalFirstActualStoreTests.OpenedWritableStoreBundle

    /// Thread-safe stub of the server's Enable Banking routes, keyed by the
    /// remote account ID. An unlisted account answers like a server without
    /// the routes.
    actor StubEnableBankingTransport: EnableBankingServerTransport {
        struct Request: Equatable {
            let accountID: String
            let startDate: String
            let aspspName: String?
        }

        private var answers: [String: Result<SimpleFINAccountDownload?, ActualAPIError>]
        private(set) var requests: [Request] = []
        private var gate: TestLatch?
        nonisolated let entered = TestLatch()

        init(_ answers: [String: Result<SimpleFINAccountDownload?, ActualAPIError>] = [:]) {
            self.answers = answers
        }

        func setAnswer(_ answer: Result<SimpleFINAccountDownload?, ActualAPIError>, for accountID: String) {
            answers[accountID] = answer
        }

        func setGate(_ gate: TestLatch?) {
            self.gate = gate
        }

        func status(token: String) async throws -> SimpleFINServerSupport { .configured }

        func transactions(
            token: String,
            accountID: String,
            startDate: String,
            aspspName: String?
        ) async throws -> SimpleFINAccountDownload? {
            requests.append(Request(accountID: accountID, startDate: startDate, aspspName: aspspName))
            if let gate {
                entered.trip()
                await gate.wait()
            }
            return try (answers[accountID] ?? .success(nil)).get()
        }
    }

    /// The server's response to one fixture scenario, decoded by the production client.
    private func enableBankingDownload(_ scenarioID: String) throws -> SimpleFINAccountDownload {
        let scenario = try EnableBankingServerFixture.load().scenario(scenarioID)
        return try ActualServerEnableBankingClient.decodeTransactionsResponse(from: Data(scenario.bodyText.utf8))
    }

    private func makeEnableBankingStore(
        simpleFIN: StubSimpleFINTransport = StubSimpleFINTransport(),
        enableBanking: StubEnableBankingTransport,
        additionalFixtureSQL: String = ""
    ) async throws -> OpenedWritableStoreBundle {
        let bundle = try await support.makeBankSyncStore(transport: simpleFIN, additionalFixtureSQL: additionalFixtureSQL)
        bundle.store.seams.enableBankingTransportFactory = { _ in enableBanking }
        return bundle
    }

    /// Links an account the way the Actual web app's `linkEnableBankingAccount` leaves it.
    private func linkEnableBanking(
        _ store: LocalFirstActualStore,
        accountID: String,
        remoteAccountID: String,
        bankName: String?
    ) async throws {
        let database = try store.requireDatabase(for: "group-1")
        let queue = await database.queue
        try await queue.write { db in
            let bankID = "bank-\(accountID)"
            try db.execute(sql: "INSERT INTO banks (id, bank_id, name) VALUES (?, ?, ?)",
                           arguments: [bankID, remoteAccountID, bankName])
            try db.execute(
                sql: "UPDATE accounts SET account_id = ?, account_sync_source = 'enableBanking', bank = ? WHERE id = ?",
                arguments: [remoteAccountID, bankID, accountID]
            )
        }
    }

    private func storedStatus(_ store: LocalFirstActualStore, accountID: String) async throws -> String? {
        let database = try store.requireDatabase(for: "group-1")
        return try await BankSyncLinkSQL.bankSyncLinkedAccounts(in: database)
            .first { $0.id == accountID }?.bankSyncStatus
    }

    // MARK: - Routing

    @Test func mixedBudgetBatchesSimpleFINThenRequestsEnableBankingPerAccountInOrder() async throws {
        let simpleFIN = StubSimpleFINTransport(
            remoteAccounts: [support.remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: ["sfin-1": SimpleFINAccountDownload(
                    transactions: [support.remoteTransaction(id: "sf-1", amount: "-10.00", dayID: "20261001", payeeName: "Coffee Shop")],
                    startingBalance: nil, errorType: nil, errorCode: nil
                )],
                errorType: nil, errorCode: nil
            )
        )
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("booked-and-pending")),
            "eb-acct-gbp": .success(try enableBankingDownload("non-eur-account")),
        ])
        let bundle = try await makeEnableBankingStore(simpleFIN: simpleFIN, enableBanking: enableBanking)
        let store = bundle.store
        try await store.bankSync.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: "Synthetic Bank")
        try await linkEnableBanking(store, accountID: "tracking", remoteAccountID: "eb-acct-gbp", bankName: nil)

        let plans = try await store.bankSyncPlans.downloadBankSyncPlans(
            accountIDs: ["credit", "savings", "tracking"],
            budgetID: "group-1"
        )

        #expect(plans.map(\.link.accountID) == ["credit", "savings", "tracking"])
        #expect(await simpleFIN.transactionsRequests.map { $0.accountIDs } == [["sfin-1"]])
        let requests = await enableBanking.requests
        #expect(requests.map(\.accountID) == ["eb-acct-checking", "eb-acct-gbp"])
        #expect(requests.map(\.aspspName) == ["Synthetic Bank", nil])
        #expect(requests.allSatisfy { $0.startDate == BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: nil) })
        #expect(plans.allSatisfy { $0.problems.isEmpty && $0.durableStatus == .ok })
        #expect(plans.allSatisfy { $0.wholeRequestFailure == nil })
        #expect(plans[0].inserts.map(\.financialID) == ["eb-ref-1001", "eb-ref-1002", "eb-tx-pend-1"])
        #expect(plans[0].inserts.map(\.cleared) == [true, true, false])
        #expect(plans[1].inserts.map(\.financialID) == ["sf-1"])
        #expect(plans[2].inserts.map(\.amountMinorUnits) == [-1999])

        for plan in plans {
            _ = try await store.bankSync.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        #expect(try await storedStatus(store, accountID: "credit") == "ok")
        #expect(try await storedStatus(store, accountID: "tracking") == "ok")
    }

    @Test func enableBankingOnlyRunNeverAsksAboutSimpleFIN() async throws {
        let simpleFIN = StubSimpleFINTransport(support: .notConfigured)
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("empty-download")),
        ])
        let bundle = try await makeEnableBankingStore(simpleFIN: simpleFIN, enableBanking: enableBanking)
        try await linkEnableBanking(bundle.store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: "Synthetic Bank")

        let plans = try await bundle.store.bankSyncPlans.downloadBankSyncPlans(accountIDs: ["credit"], budgetID: "group-1")

        #expect(plans.count == 1)
        #expect(await simpleFIN.statusRequests == 0)
        #expect(await simpleFIN.transactionsRequests.isEmpty)
    }

    @Test func otherProvidersAreRefused() async throws {
        let bundle = try await makeEnableBankingStore(enableBanking: StubEnableBankingTransport())
        try await linkEnableBanking(bundle.store, accountID: "credit", remoteAccountID: "gc-1", bankName: nil)
        let queue = try await bundle.store.requireDatabase(for: "group-1").queue
        try await queue.write { db in
            try db.execute(sql: "UPDATE accounts SET account_sync_source = 'goCardless' WHERE id = 'credit'")
        }
        await #expect(throws: BankSyncWorkflows.BankSyncStoreError.unsupportedProvider) {
            _ = try await bundle.store.bankSyncPlans.downloadBankSyncPlans(accountIDs: ["credit"], budgetID: "group-1")
        }
    }

    // MARK: - Per-account failures

    @Test(arguments: ["routes-missing", "not-configured"])
    func serverWithoutEnableBankingMarksThoseAccountsNotConfiguredAndKeepsSimpleFIN(scenarioID: String) async throws {
        let simpleFIN = StubSimpleFINTransport(
            remoteAccounts: [support.remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: ["sfin-1": SimpleFINAccountDownload(
                    transactions: [support.remoteTransaction(id: "sf-1", amount: "-10.00", dayID: "20261001", payeeName: "Coffee Shop")],
                    startingBalance: nil, errorType: nil, errorCode: nil
                )],
                errorType: nil, errorCode: nil
            )
        )
        // routes-missing: an unlisted account answers like a server without the routes.
        let enableBanking = StubEnableBankingTransport(scenarioID == "not-configured"
            ? ["eb-acct-checking": .success(try enableBankingDownload("not-configured"))]
            : [:])
        let bundle = try await makeEnableBankingStore(simpleFIN: simpleFIN, enableBanking: enableBanking)
        let store = bundle.store
        try await store.bankSync.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: "Synthetic Bank")
        try await linkEnableBanking(store, accountID: "tracking", remoteAccountID: "eb-acct-gbp", bankName: "Synthetic UK Bank")

        let plans = try await store.bankSyncPlans.downloadBankSyncPlans(
            accountIDs: ["credit", "savings", "tracking"], budgetID: "group-1"
        )

        #expect(plans.map(\.durableStatus) == [.notConfigured, .ok, .notConfigured])
        #expect(plans[1].inserts.count == 1)
        #expect(plans[0].balanceDisposition == .preserve)
        // The credentials are server-wide: the second account is not asked again.
        #expect(await enableBanking.requests.map(\.accountID) == ["eb-acct-checking"])
        for plan in plans {
            _ = try await store.bankSync.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        #expect(try await storedStatus(store, accountID: "credit") == "not-configured")
        #expect(try await storedStatus(store, accountID: "savings") == "ok")
    }

    @Test func expiredConsentIsReauthRequiredAndKeepsTheBalance() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("expired-session-unauthorized")),
        ])
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        let store = bundle.store
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: "Synthetic Bank")

        let plan = try await store.downloadBankSyncPlan(accountID: "credit", budgetID: "group-1")
        #expect(plan.durableStatus == .reauthRequired)
        #expect(plan.balanceDisposition == .preserve)
        #expect(plan.inserts.isEmpty && plan.problems.isEmpty && plan.openingBalance == nil)

        _ = try await store.bankSync.applyBankSyncPlan(plan, budgetID: "group-1")
        #expect(try await storedStatus(store, accountID: "credit") == "reauth-required")
    }

    @Test func oneAccountsFailedRequestDoesNotStopTheNext() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .failure(.transport(.timedOut)),
            "eb-acct-gbp": .success(try enableBankingDownload("non-eur-account")),
        ])
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        let store = bundle.store
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: "Synthetic Bank")
        try await linkEnableBanking(store, accountID: "tracking", remoteAccountID: "eb-acct-gbp", bankName: "Synthetic UK Bank")

        let plans = try await store.bankSyncPlans.downloadBankSyncPlans(accountIDs: ["credit", "tracking"], budgetID: "group-1")

        #expect(plans.map(\.durableStatus) == [.timedOut, .ok])
        #expect(plans[0].balanceDisposition == .preserve)
        #expect(plans[1].inserts.count == 1)
    }

    @Test func expiredSignInEndsTheRun() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .failure(.httpStatus(401)),
            "eb-acct-gbp": .success(try enableBankingDownload("non-eur-account")),
        ])
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        try await linkEnableBanking(bundle.store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)
        try await linkEnableBanking(bundle.store, accountID: "tracking", remoteAccountID: "eb-acct-gbp", bankName: nil)

        await #expect(throws: ActualAPIError.self) {
            _ = try await bundle.store.bankSyncPlans.downloadBankSyncPlans(accountIDs: ["credit", "tracking"], budgetID: "group-1")
        }
        #expect(await enableBanking.requests.count == 1)
    }

    @Test func budgetSwitchMidLoopStopsBeforeTheNextAccount() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("booked-and-pending")),
            "eb-acct-gbp": .success(try enableBankingDownload("non-eur-account")),
        ])
        let gate = TestLatch()
        await enableBanking.setGate(gate)
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        let store = bundle.store
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)
        try await linkEnableBanking(store, accountID: "tracking", remoteAccountID: "eb-acct-gbp", bankName: nil)

        let run = Task { @MainActor in
            try await store.bankSyncPlans.downloadBankSyncPlans(accountIDs: ["credit", "tracking"], budgetID: "group-1")
        }
        await enableBanking.entered.wait()
        store.closeOpenBudget()
        gate.trip()

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(await enableBanking.requests.map(\.accountID) == ["eb-acct-checking"])
    }

    // MARK: - Download preparation

    /// Two rows the bank sent without any ID, same day and amount, import as two rows; the next
    /// sync matches them by amount and date instead of importing them again.
    @Test func rowsWithoutIDsImportWithoutAnImportedIDAndMatchOnTheNextSync() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("missing-ids")),
        ])
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        let store = bundle.store
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)

        let first = try await store.downloadBankSyncPlan(accountID: "credit", budgetID: "group-1")
        #expect(first.problems.isEmpty)
        #expect(first.inserts.map(\.financialID) == ["eb-tx-only-2001", "eb-tx-after-empty-ref", nil, nil])
        _ = try await store.bankSync.applyBankSyncPlan(first, budgetID: "group-1")

        let second = try await store.downloadBankSyncPlan(accountID: "credit", budgetID: "group-1")
        #expect(second.problems.isEmpty)
        #expect(second.inserts.isEmpty)
        #expect(second.updates.isEmpty)
        #expect(second.unchangedCount == 4)
    }

    @Test func simpleFINStillRefusesARowWithoutATransactionID() async throws {
        let simpleFIN = StubSimpleFINTransport(
            remoteAccounts: [support.remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: ["sfin-1": SimpleFINAccountDownload(
                    transactions: [support.remoteTransaction(id: " ", amount: "-10.00", dayID: "20261001", payeeName: "Coffee Shop")],
                    startingBalance: nil, errorType: nil, errorCode: nil
                )],
                errorType: nil, errorCode: nil
            )
        )
        let bundle = try await makeEnableBankingStore(simpleFIN: simpleFIN, enableBanking: StubEnableBankingTransport())
        try await bundle.store.bankSync.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")

        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.problems.map(\.message) == ["Missing transaction ID"])
    }

    /// A pending card payment the bank later books under a different ID updates the imported row.
    @Test func pendingRowBookedUnderANewIDUpdatesInsteadOfDuplicating() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("pending-before-booking")),
        ])
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        let store = bundle.store
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)
        let pending = try await store.downloadBankSyncPlan(accountID: "credit", budgetID: "group-1")
        #expect(pending.inserts.map(\.cleared) == [false])
        _ = try await store.bankSync.applyBankSyncPlan(pending, budgetID: "group-1")

        await enableBanking.setAnswer(.success(try enableBankingDownload("pending-after-booking")), for: "eb-acct-checking")
        let booked = try await store.downloadBankSyncPlan(accountID: "credit", budgetID: "group-1")

        #expect(booked.inserts.isEmpty)
        #expect(booked.updates.count == 1)
        #expect(booked.updates.first?.financialID == "eb-ref-book-77")
        #expect(booked.updates.first?.cleared == true)
    }

    @Test func currencyOtherThanTheBudgetsIsABlockingProblem() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-gbp": .success(try enableBankingDownload("non-eur-account")),
        ])
        let bundle = try await makeEnableBankingStore(
            enableBanking: enableBanking,
            additionalFixtureSQL: """
                CREATE TABLE IF NOT EXISTS preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences VALUES ('defaultCurrencyCode', 'EUR');
                """
        )
        try await linkEnableBanking(bundle.store, accountID: "credit", remoteAccountID: "eb-acct-gbp", bankName: nil)

        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "credit", budgetID: "group-1")
        #expect(plan.problems.map(\.message) == ["Currency mismatch (GBP bank transaction, EUR budget)"])
        #expect(plan.balanceDisposition == .clear)
        #expect(plan.openingBalance == nil)
    }

    /// First sync of an empty account: the balance is the server's minor-unit
    /// balance, and the opening balance subtracts the planned inserts.
    @Test func firstSyncTakesTheServersMinorUnitBalance() async throws {
        let download = try enableBankingDownload("booked-and-pending")
        let enableBanking = StubEnableBankingTransport(["eb-acct-checking": .success(download)])
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        try await linkEnableBanking(bundle.store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)

        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "credit", budgetID: "group-1")
        let balance = try #require(download.minorUnitBalance?.amount)
        #expect(plan.balanceDisposition == .set(balance))
        #expect(plan.openingBalance?.amountMinorUnits == balance - plan.inserts.reduce(0) { $0 + $1.amountMinorUnits })
        #expect(plan.openingBalance?.dayID == "20261001")
    }

    // MARK: - Balance rule

    @Test func minorUnitBalanceIsSetOnlyForATwoDecimalBudgetInItsCurrency() throws {
        let download = try enableBankingDownload("booked-and-pending")
        let balance = try #require(download.minorUnitBalance)
        func disposition(_ download: SimpleFINAccountDownload, _ code: String) -> BankSyncReview.BalanceDisposition {
            BankSyncBalancePlanning.disposition(download: download, fallbackRemote: nil, currency: BudgetCurrency.catalog(code: code))
        }
        #expect(disposition(download, "") == .set(balance.amount))
        #expect(disposition(download, "EUR") == .set(balance.amount))
        #expect(disposition(download, "USD") == .clear)
        #expect(disposition(try enableBankingDownload("zero-decimal-currency"), "JPY") == .clear)
        #expect(disposition(try enableBankingDownload("balances-empty"), "EUR") == .clear)
        #expect(disposition(try enableBankingDownload("rate-limited"), "EUR") == .preserve)
    }
}
