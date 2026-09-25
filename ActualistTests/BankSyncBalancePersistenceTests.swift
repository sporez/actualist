import GRDB
import Testing
@testable import Actualist

/// First-sync planning and account-balance completion behavior. Kept separate
/// from transaction matching so balance persistence has one focused test seam.
extension LocalFirstActualStoreTests {
    @Test func firstApplyInsertsBothDownloadsWithOpeningBalanceAndLinkStamping() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount()],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop"),
                            remoteTransaction(id: "d2", amount: "5.00", dayID: "20260705", payeeName: "Refund Source")
                        ],
                        currentBalance: SimpleFINBalanceAmount(amount: "100.00", currency: "USD"),
                        startingBalance: 10_000,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(transport: transport)
        let store = bundle.store

        try await store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")

        let plan = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.count == 2)
        #expect(plan.updates.isEmpty)
        #expect(plan.unchangedCount == 0)
        #expect(plan.problems.isEmpty)
        #expect(plan.durableStatus == .ok)
        #expect(plan.balanceDisposition == .set(10_000))
        // Opening balance: 100.00 − (−10.00 + 5.00) = 105.00 in minor units,
        // dated to the oldest downloaded day.
        #expect(plan.openingBalance == BankSyncReconciliation.OpeningBalance(amountMinorUnits: 10_500, dayID: "20260701"))

        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let result = try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        #expect(result.insertedCount == 2)
        #expect(result.updatedCount == 0)
        #expect(result.openingBalanceInserted)
        #expect(result.insertedTransactionIDs.count == 3)

        let messages = try storedCRDTMessages(at: databaseURL)
        let accountMessages = linkedMessages(messages, row: "savings")
        #expect(accountMessages.contains { $0.column == "account_id" && $0.serializedValue == "S:sfin-1" })
        #expect(accountMessages.contains { $0.column == "account_sync_source" && $0.serializedValue == "S:simpleFin" })
        #expect(accountMessages.contains { $0.column == "bank" && $0.serializedValue.hasPrefix("S:") })

        for downloadID in ["d1", "d2"] {
            #expect(messages.contains {
                $0.dataset == "transactions" && $0.column == "financial_id" && $0.serializedValue == "S:\(downloadID)"
            })
        }
        #expect(messages.contains {
            $0.dataset == "transactions" && $0.column == "starting_balance_flag" && $0.serializedValue == "N:1"
        })
        let stamps = accountMessages.filter { $0.column == "last_sync" || $0.column == "bank_sync_status" }
        #expect(stamps.contains { $0.column == "bank_sync_status" && $0.serializedValue == "S:ok" })
        #expect(stamps.contains { $0.column == "last_sync" && !$0.serializedValue.isEmpty && $0.serializedValue != "0:" })
        #expect(accountMessages.contains {
            $0.column == "balance_current" && $0.serializedValue == "N:10000"
        })

        let queue = try DatabaseQueue(path: databaseURL.path)
        let liveCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transactions WHERE acct = 'savings' AND (tombstone = 0 OR tombstone IS NULL)"
            )
        }
        #expect(liveCount == 3)
    }

    @Test func batchPlanningUsesOneProviderProbeDownloadAndMetadataRequest() async throws {
        let firstRemote = remoteAccount(id: "sfin-1", balance: "0.00")
        let secondRemote = remoteAccount(id: "sfin-2", balance: "0.00")
        let transport = StubSimpleFINTransport(
            remoteAccounts: [firstRemote, secondRemote],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [],
                        currentBalance: SimpleFINBalanceAmount(amount: "11.11", currency: "USD"),
                        startingBalance: nil, errorType: nil, errorCode: nil
                    ),
                    "sfin-2": SimpleFINAccountDownload(
                        transactions: [],
                        currentBalance: SimpleFINBalanceAmount(amount: "-22.22", currency: "USD"),
                        startingBalance: nil, errorType: nil, errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(transport: transport)
        try await bundle.store.linkBankAccount("savings", to: firstRemote, budgetID: "group-1")
        try await bundle.store.linkBankAccount("credit", to: secondRemote, budgetID: "group-1")

        let plans = try await bundle.store.downloadBankSyncPlans(
            accountIDs: ["savings", "credit"], budgetID: "group-1"
        )

        #expect(plans.map(\.link.accountID) == ["savings", "credit"])
        #expect(plans.map(\.balanceDisposition) == [.set(1_111), .set(-2_222)])
        for plan in plans {
            _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        #expect(await transport.statusRequests == 1)
        #expect(await transport.accountsRequests == 1)
        let requests = await transport.transactionsRequests
        #expect(requests.count == 1)
        #expect(requests.first?.accountIDs == ["sfin-1", "sfin-2"])
        #expect(requests.first?.startDates.count == 2)
        let queue = try DatabaseQueue(
            path: try bundle.fileManager.databaseURL(fileID: "file-1").path
        )
        let balances = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, balance_current FROM accounts WHERE id IN ('savings', 'credit')"
            ).reduce(into: [String: Int]()) { values, row in
                values[row["id"]] = row["balance_current"]
            }
        }
        #expect(balances == ["savings": 1_111, "credit": -2_222])
    }

    @Test func optionalBalanceMetadataFailureDoesNotDiscardTransactionBatch() async throws {
        let remote = remoteAccount(balance: "0.00")
        let transport = StubSimpleFINTransport(
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(
                                id: "still-valid", amount: "-10.00",
                                dayID: "20260701", payeeName: "Coffee Shop"
                            )
                        ],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            ),
            accountsFailure: .decoding
        )
        let bundle = try await makeBankSyncStore(transport: transport)
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings", budgetID: "group-1"
        )

        #expect(plan.inserts.count == 1)
        #expect(plan.openingBalance == nil)
        #expect(await transport.accountsRequests == 1)
    }

    @Test func successfulDownloadReplacesStaleBalanceInSQLiteAndOutbox() async throws {
        let bundle = try await makeBalancePersistenceBundle(
            download: SimpleFINAccountDownload(
                transactions: [],
                currentBalance: SimpleFINBalanceAmount(amount: "-7495.11", currency: "USD"),
                startingBalance: nil,
                errorType: nil,
                errorCode: nil
            )
        )
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let queue = try DatabaseQueue(path: databaseURL.path)
        let beforeOutbox = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? 0
        }

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings", budgetID: "group-1"
        )
        #expect(plan.balanceDisposition == .set(-749_511))
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        let completion = try await queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT balance_current FROM accounts WHERE id = 'savings'"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? 0
            )
        }
        #expect(completion.0 == -749_511)
        #expect(completion.1 == beforeOutbox + 3)
        let messages = try storedCRDTMessages(at: databaseURL)
        #expect(messages.contains {
            $0.dataset == "accounts" && $0.row == "savings"
                && $0.column == "balance_current" && $0.serializedValue == "N:-749511"
        })

        bundle.store.reset()
        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        let reopened = try await bundle.store.accountReconciliationSnapshot(
            budgetID: "group-1", accountID: "savings"
        )
        #expect(reopened.lastSyncedBalance == -749_511)

        let peerURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            """)
        let peer = try BudgetDatabase(databaseURL: peerURL)
        let completionMessages = messages.filter {
            $0.dataset == "accounts" && $0.row == "savings"
                && ["balance_current", "last_sync", "bank_sync_status"].contains($0.column)
        }
        #expect(try await peer.applyRemoteSyncMessages(completionMessages) == 3)
        let peerQueue = try DatabaseQueue(path: peerURL.path)
        let peerBalance = try await peerQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT balance_current FROM accounts WHERE id = 'savings'")
        }
        #expect(peerBalance == -749_511)
    }

    @Test func successfulDownloadWithoutUsableBalanceClearsStaleEvidence() async throws {
        let bundle = try await makeBalancePersistenceBundle(
            download: SimpleFINAccountDownload(
                transactions: [],
                currentBalance: SimpleFINBalanceAmount(amount: "unreadable", currency: "USD"),
                startingBalance: nil,
                errorType: nil,
                errorCode: nil
            )
        )
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings", budgetID: "group-1"
        )
        #expect(plan.balanceDisposition == .clear)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        let queue = try DatabaseQueue(path: databaseURL.path)
        let balance = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT balance_current FROM accounts WHERE id = 'savings'")
        }
        #expect(balance == nil)
        let messages = try storedCRDTMessages(at: databaseURL)
        #expect(messages.contains {
            $0.dataset == "accounts" && $0.row == "savings"
                && $0.column == "balance_current" && $0.serializedValue == "0:"
        })
    }

    @Test func failedDownloadPreservesStaleBalance() async throws {
        let bundle = try await makeBalancePersistenceBundle(
            download: SimpleFINAccountDownload(
                transactions: [],
                currentBalance: SimpleFINBalanceAmount(amount: "999.99", currency: "USD"),
                startingBalance: nil,
                errorType: "provider_error",
                errorCode: "TIMED_OUT"
            )
        )
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let beforeMessages = try storedCRDTMessages(at: databaseURL).count

        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings", budgetID: "group-1"
        )
        #expect(plan.balanceDisposition == .preserve)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        let queue = try DatabaseQueue(path: databaseURL.path)
        let balance = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT balance_current FROM accounts WHERE id = 'savings'")
        }
        #expect(balance == -228_364)
        let newMessages = Array(try storedCRDTMessages(at: databaseURL).dropFirst(beforeMessages))
        #expect(!newMessages.contains { $0.column == "balance_current" })
    }

    private func makeBalancePersistenceBundle(
        download: SimpleFINAccountDownload
    ) async throws -> OpenedWritableStoreBundle {
        let transport = StubSimpleFINTransport(response: SimpleFINTransactionsResponse(
            downloads: ["sfin-1": download],
            errorType: nil,
            errorCode: nil
        ))
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences VALUES ('defaultCurrencyCode', 'USD');
                ALTER TABLE accounts ADD COLUMN last_reconciled TEXT;
                ALTER TABLE accounts ADD COLUMN balance_current INTEGER;
                UPDATE accounts SET balance_current = -228364 WHERE id = 'savings';
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, cleared, is_parent)
                    VALUES ('prior-savings', 'savings', 20260701, 100, NULL, 0, 'coffee', 1, 0);
                """
        )
        try await bundle.store.linkBankAccount(
            "savings", to: remoteAccount(), budgetID: "group-1"
        )
        return bundle
    }
}
