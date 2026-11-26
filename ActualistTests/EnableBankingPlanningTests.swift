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
    private typealias StubEnableBankingTransport = EnableBankingTestSupport.StubTransport

    private func enableBankingDownload(_ scenarioID: String) throws -> SimpleFINAccountDownload {
        try EnableBankingTestSupport.download(scenarioID)
    }

    private func makeEnableBankingStore(
        simpleFIN: StubSimpleFINTransport = StubSimpleFINTransport(),
        enableBanking: StubEnableBankingTransport,
        additionalFixtureSQL: String = ""
    ) async throws -> OpenedWritableStoreBundle {
        try await EnableBankingTestSupport.makeStore(
            support: support, simpleFIN: simpleFIN, enableBanking: enableBanking, additionalFixtureSQL: additionalFixtureSQL
        )
    }

    private func linkEnableBanking(
        _ store: LocalFirstActualStore,
        accountID: String,
        remoteAccountID: String,
        bankName: String?
    ) async throws {
        try await EnableBankingTestSupport.link(store, accountID: accountID, remoteAccountID: remoteAccountID, bankName: bankName)
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
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "credit") == "ok")
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "tracking") == "ok")
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

    // MARK: - SimpleFIN failure and deadlines

    /// Actual's web Sync All carries on with the other providers after the SimpleFIN batch fails.
    @Test func simpleFINFailureDoesNotStopTheEnableBankingAccounts() async throws {
        // The status answers; the transactions route is missing, so the batch throws.
        let simpleFIN = StubSimpleFINTransport(remoteAccounts: [support.remoteAccount(balance: "0.00")], response: nil)
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("booked-and-pending")),
        ])
        let bundle = try await makeEnableBankingStore(simpleFIN: simpleFIN, enableBanking: enableBanking)
        let store = bundle.store
        try await store.bankSync.linkBankAccount("savings", to: support.remoteAccount(), budgetID: "group-1")
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)

        let run = try await store.bankSyncPlans.downloadBankSyncRun(accountIDs: ["savings", "credit"], budgetID: "group-1")

        #expect(run.plans.map(\.link.accountID) == ["credit"])
        #expect(run.plans.first?.inserts.count == 3)
        #expect(run.simpleFINFailure as? BankSyncWorkflows.BankSyncStoreError == .notConfigured)
        #expect(await enableBanking.requests.count == 1)
        // Without Enable Banking accounts the failure still ends the run.
        await #expect(throws: BankSyncWorkflows.BankSyncStoreError.notConfigured) {
            _ = try await store.bankSyncPlans.downloadBankSyncRun(accountIDs: ["savings"], budgetID: "group-1")
        }
    }

    @Test func unreachableSimpleFINRecordsItsStatusAndTheEnableBankingAccountsStillDownload() async throws {
        let simpleFIN = StubSimpleFINTransport(failure: .transport(.cannotConnectToHost))
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("empty-download")),
        ])
        let bundle = try await makeEnableBankingStore(simpleFIN: simpleFIN, enableBanking: enableBanking)
        let store = bundle.store
        let queue = try await store.requireDatabase(for: "group-1").queue
        // A SimpleFIN link left by the web app; linking here would ask the unreachable server.
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE accounts SET account_id = 'sfin-1', account_sync_source = 'simpleFin' WHERE id = 'savings'
                """)
        }
        try await linkEnableBanking(store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)

        let run = try await store.bankSyncPlans.downloadBankSyncRun(accountIDs: ["savings", "credit"], budgetID: "group-1")

        #expect(run.plans.map(\.link.accountID) == ["credit"])
        #expect(run.simpleFINFailure is ActualAPIError)
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "savings") == "failed")
    }

    /// A background run stops starting Enable Banking requests at its deadline; nothing is stored
    /// for the accounts it did not reach.
    @Test func passedDeadlineLeavesTheEnableBankingAccountsForTheNextRun() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("booked-and-pending")),
        ])
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        try await linkEnableBanking(bundle.store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)

        let run = try await bundle.store.bankSyncPlans.downloadBankSyncRun(
            accountIDs: ["credit"], budgetID: "group-1", enableBankingDeadline: .now
        )

        #expect(run.plans.isEmpty)
        #expect(run.simpleFINFailure == nil)
        #expect(await enableBanking.requests.isEmpty)
        #expect(try await EnableBankingTestSupport.storedStatus(bundle.store, accountID: "credit") == nil)
    }

    @Test func requestStillRunningAtTheDeadlineIsAbandoned() async throws {
        let enableBanking = StubEnableBankingTransport([
            "eb-acct-checking": .success(try enableBankingDownload("booked-and-pending")),
            "eb-acct-gbp": .success(try enableBankingDownload("non-eur-account")),
        ])
        let gate = TestLatch()
        await enableBanking.setGate(gate)
        let bundle = try await makeEnableBankingStore(enableBanking: enableBanking)
        try await linkEnableBanking(bundle.store, accountID: "credit", remoteAccountID: "eb-acct-checking", bankName: nil)
        try await linkEnableBanking(bundle.store, accountID: "tracking", remoteAccountID: "eb-acct-gbp", bankName: nil)
        // The gate stays closed past the deadline, so the first request is still running at it.
        defer { gate.trip() }

        let run = try await bundle.store.bankSyncPlans.downloadBankSyncRun(
            accountIDs: ["credit", "tracking"],
            budgetID: "group-1",
            enableBankingDeadline: ContinuousClock.now.advanced(by: .milliseconds(300))
        )

        #expect(run.plans.isEmpty)
        #expect(await enableBanking.requests.map(\.accountID) == ["eb-acct-checking"])
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
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "credit") == "not-configured")
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "savings") == "ok")
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
        #expect(try await EnableBankingTestSupport.storedStatus(store, accountID: "credit") == "reauth-required")
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
