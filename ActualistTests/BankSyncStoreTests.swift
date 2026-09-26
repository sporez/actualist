import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 3 store apply path (plan `simplefin-bank-sync-plan.md`): stubbed
/// server transport, fixture budget, real CRDT writes — no network.
extension LocalFirstActualStoreTests {
    /// Thread-safe stub of the server's SimpleFIN routes. An actor so the
    /// `SimpleFINServerTransport` Sendable conformance is honest.
    actor StubSimpleFINTransport: SimpleFINServerTransport {
        var support: SimpleFINServerSupport
        var remoteAccounts: [SimpleFINRemoteAccount]?
        var response: SimpleFINTransactionsResponse?
        /// When set, every route throws instead of answering (server unreachable).
        var failure: ActualAPIError?
        /// Route-specific failure used to verify account-list errors are not
        /// silently turned into an empty list.
        var accountsFailure: ActualAPIError?
        private(set) var transactionsRequests: [(accountIDs: [String], startDates: [String])] = []
        private(set) var statusRequests = 0
        private(set) var accountsRequests = 0

        init(
            support: SimpleFINServerSupport = .configured,
            remoteAccounts: [SimpleFINRemoteAccount]? = [],
            response: SimpleFINTransactionsResponse? = SimpleFINTransactionsResponse(
                downloads: [:],
                errorType: nil,
                errorCode: nil
            ),
            failure: ActualAPIError? = nil,
            accountsFailure: ActualAPIError? = nil
        ) {
            self.support = support
            self.remoteAccounts = remoteAccounts
            self.response = response
            self.failure = failure
            self.accountsFailure = accountsFailure
        }

        func setFailure(_ error: ActualAPIError?) {
            failure = error
        }

        func simpleFINStatus(token: String) async throws -> SimpleFINServerSupport {
            statusRequests += 1
            if let failure {
                throw failure
            }
            return support
        }

        func simpleFINAccounts(token: String) async throws -> [SimpleFINRemoteAccount]? {
            accountsRequests += 1
            if let failure = accountsFailure ?? failure {
                throw failure
            }
            return remoteAccounts
        }

        func simpleFINTransactions(
            token: String,
            accountIDs: [String],
            startDates: [String]
        ) async throws -> SimpleFINTransactionsResponse? {
            transactionsRequests.append((accountIDs, startDates))
            return response
        }
    }

    static let bankSyncColumnsSQL = """
        ALTER TABLE transactions ADD COLUMN financial_id TEXT;
        ALTER TABLE transactions ADD COLUMN imported_description TEXT;
        ALTER TABLE transactions ADD COLUMN sort_order REAL;
        ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
        ALTER TABLE transactions ADD COLUMN starting_balance_flag INTEGER;
        INSERT INTO payees VALUES ('sb', 'Starting Balance', NULL, 0);
        INSERT INTO payee_mapping VALUES ('sb', 'sb');
        """

    @discardableResult
    func makeBankSyncStore(
        transport: StubSimpleFINTransport,
        additionalFixtureSQL: String = "",
        // Same fresh-fake default as makeOpenedWritableStoreBundle. Explicit
        // backends are forwarded unchanged.
        keychainBackend: any KeychainBackend = FakeKeychainBackend()
    ) async throws -> OpenedWritableStoreBundle {
        let bundle = try await makeOpenedWritableStoreBundle(
            keychainBackend: keychainBackend,
            simpleFINTransportFactory: { _ in transport },
            additionalFixtureSQL: additionalFixtureSQL + "\n" + Self.bankSyncColumnsSQL
        )
        bundle.store.openedServerURLString = "https://sync.example"
        try bundle.keychain.saveActualSyncToken("test-sync-token")
        return bundle
    }

    func remoteAccount(id: String = "sfin-1", balance: String = "100.00") -> SimpleFINRemoteAccount {
        SimpleFINRemoteAccount(
            accountID: id,
            name: "Checking",
            balance: balance,
            currency: "USD",
            institution: nil,
            orgName: "Chase",
            orgDomain: "chase.example",
            orgID: "org-1"
        )
    }

    func remoteTransaction(
        id: String,
        amount: String,
        dayID: String,
        payeeName: String,
        booked: Bool = true
    ) -> SimpleFINRemoteTransaction {
        // UTC noon of the day, in UNIX seconds.
        var components = DateComponents()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = Int(dayID.prefix(4))
        components.month = Int(dayID.dropFirst(4).prefix(2))
        components.day = Int(dayID.suffix(2))
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let seconds = Int64(calendar.date(from: components)!.timeIntervalSince1970)
        return SimpleFINRemoteTransaction(
            id: id,
            dateUnixSeconds: seconds,
            amount: amount,
            currency: "USD",
            payeeName: payeeName,
            notes: "coffee #latte",
            booked: booked,
            accountID: "sfin-1"
        )
    }

    func linkedMessages(_ messages: [ActualSyncDecodedMessage], row: String) -> [ActualSyncDecodedMessage] {
        messages.filter { $0.dataset == "accounts" && $0.row == row }
    }

    // MARK: - Second apply is a no-op

    @Test func secondApplyHasZeroInsertsAndZeroUpdates() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop")
                        ],
                        startingBalance: nil,
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

        let first = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        _ = try await store.applyBankSyncPlan(first, budgetID: "group-1")

        let second = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(second.inserts.isEmpty)
        #expect(second.updates.isEmpty)
        #expect(second.unchangedCount == 1)
        #expect(second.openingBalance == nil)
        let result = try await store.applyBankSyncPlan(second, budgetID: "group-1")
        #expect(result.insertedCount == 0)
        #expect(result.updatedCount == 0)
        #expect(!result.openingBalanceInserted)
        #expect(result.insertedTransactionIDs.isEmpty)
    }

    // MARK: - Hand-entered same amount is adopted, not duplicated

    @Test func handEnteredSameAmountInsideWindowIsAdopted() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop")
                        ],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        // Hand-entered row inside the window: same payee, same amount,
        // no financial id yet.
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('hand-1', 'savings', 20260701, -1000, NULL, 0, 'coffee', NULL, 0, 0);
                """
        )
        let store = bundle.store
        try await store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")

        let plan = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.isEmpty)
        #expect(plan.updates.count == 1)
        #expect(plan.updates.first?.existingID == "hand-1")
        #expect(plan.updates.first?.financialID == "d1")

        _ = try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        let messages = try storedCRDTMessages(at: databaseURL)
        #expect(messages.contains {
            $0.dataset == "transactions" && $0.row == "hand-1"
                && $0.column == "financial_id" && $0.serializedValue == "S:d1"
        })
    }

    @Test func matchingRemoveNotesRulePreventsBankNoteWrite() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(
                                id: "rule-note",
                                amount: "-10.00",
                                dayID: "20260701",
                                payeeName: "Coffee Shop"
                            )
                        ],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: """
                INSERT INTO transactions
                    (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                VALUES ('rule-match', 'savings', 20260701, -1000, NULL, 0, 'coffee', NULL, 0, 0);
                CREATE TABLE rules (
                    id TEXT PRIMARY KEY,
                    conditions TEXT,
                    actions TEXT,
                    tombstone INTEGER
                );
                INSERT INTO rules VALUES (
                    'remove-bank-notes',
                    '[{"field":"payee_name","op":"is","value":"Coffee Shop"}]',
                    '[{"field":"notes","op":"set","value":""}]',
                    0
                );
                """
        )
        let store = bundle.store
        try await store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")

        let plan = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        let detail = try #require(plan.matchDetails.first)
        #expect(!detail.changes.contains { $0.field == .notes })

        _ = try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.row == "rule-match" && $0.column == "notes"
        })
    }

    // MARK: - Split-parent cleared cascade in one commit

    @Test func splitParentMatchWritesClearedCascadeOntoLiveChildren() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d2", amount: "-50.00", dayID: "20260705", payeeName: "Coffee Shop")
                        ],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, cleared, is_parent)
                VALUES ('p1', 'savings', 20260705, -5000, NULL, 0, 'coffee', 0, 1);
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, cleared, isChild, parent_id)
                VALUES ('c1', 'savings', 20260705, -3000, 'groceries', 0, 'coffee', 0, 1, 'p1');
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, cleared, isChild, parent_id)
                VALUES ('c2', 'savings', 20260705, -2000, 'dining', 0, 'coffee', 0, 1, 'p1');
                """
        )
        let store = bundle.store
        try await store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")

        let plan = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.updates.count == 1)
        #expect(plan.updates.first?.existingID == "p1")
        #expect(Set(plan.updates.first?.childIDs ?? []) == ["c1", "c2"])

        _ = try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        let messages = try storedCRDTMessages(at: databaseURL)
        for row in ["p1", "c1", "c2"] {
            #expect(messages.contains {
                $0.dataset == "transactions" && $0.row == row && $0.column == "cleared" && $0.serializedValue == "N:1"
            })
        }
        // One commit for the plan: parent and children cleared messages
        // share the commit; a child carries no financial_id message.
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.row == "c1" && $0.column == "financial_id"
        })
    }

    @Test func unmigratedSplitChildrenStillReceiveClearedCascade() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d2", amount: "-50.00", dayID: "20260705", payeeName: "Coffee Shop")
                        ],
                        startingBalance: nil,
                        errorType: nil,
                        errorCode: nil
                    )
                ],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await makeBankSyncStore(
            transport: transport,
            additionalFixtureSQL: """
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, cleared, is_parent)
                VALUES ('p1', 'savings', 20260705, -5000, NULL, 0, 'coffee', 0, 1);
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, cleared, parent_id)
                VALUES ('c1', 'savings', 20260705, -3000, 'groceries', 0, 'coffee', 0, 'p1');
                INSERT INTO transactions (id, acct, date, amount, category, tombstone, description, cleared, parent_id)
                VALUES ('c2', 'savings', 20260705, -2000, 'dining', 0, 'coffee', 0, 'p1');
                """
        )
        let store = bundle.store
        try await store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")

        let plan = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.updates.first?.existingID == "p1")
        #expect(Set(plan.updates.first?.childIDs ?? []) == ["c1", "c2"])

        _ = try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        for row in ["p1", "c1", "c2"] {
            #expect(messages.contains {
                $0.dataset == "transactions" && $0.row == row && $0.column == "cleared" && $0.serializedValue == "N:1"
            })
        }
    }

    // MARK: - Link metadata / unlink

    @Test func linkUsesNormalizedInstitutionWhenOrgNameIsAbsent() async throws {
        let bundle = try await makeBankSyncStore(transport: StubSimpleFINTransport())
        let remote = SimpleFINRemoteAccount(
            accountID: "normalized-1",
            name: "Checking",
            balance: "0.00",
            currency: "USD",
            institution: "Friendly Bank",
            orgName: nil,
            orgDomain: "friendly.example",
            orgID: nil
        )

        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")

        let queue = try DatabaseQueue(path: try bundle.fileManager.databaseURL(fileID: "file-1").path)
        let bankName = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM banks WHERE bank_id = 'friendly.example'")
        }
        #expect(bankName == "Friendly Bank")
    }

    @Test func unlinkClearsLinkColumnsAndLeavesTransactions() async throws {
        let transport = StubSimpleFINTransport()
        let bundle = try await makeBankSyncStore(transport: transport)
        let store = bundle.store
        try await store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")

        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        var messages = try storedCRDTMessages(at: databaseURL)
        #expect(linkedMessages(messages, row: "savings").count == 3)

        try await store.unlinkBankAccount("savings", budgetID: "group-1")
        messages = try storedCRDTMessages(at: databaseURL)
        let unlinkMessages = messages.filter {
            $0.dataset == "accounts" && $0.row == "savings" && $0.serializedValue == "0:"
        }
        let clearedColumns = Set(unlinkMessages.map(\.column))
        #expect(clearedColumns == [
            "account_id", "account_sync_source", "bank", "balance_current",
            "balance_available", "balance_limit", "bank_sync_status"
        ])
    }

    // MARK: - Review without confirm / stale generation

    @Test func downloadWithoutConfirmLeavesDatabaseUntouched() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount()],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop")
                        ],
                        startingBalance: 5_000,
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

        _ = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")

        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let queue = try DatabaseQueue(path: databaseURL.path)
        let count = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE acct = 'savings'")
        }
        #expect(count == 0)
        let messages = try storedCRDTMessages(at: databaseURL)
        #expect(!messages.contains { $0.dataset == "accounts" && $0.row == "savings" && $0.column == "last_sync" })
        #expect(try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM banks") 
        } == 1) // only the link's bank row
    }

    @Test func unresolvedNormalizationProblemsCannotApplyOrStampSuccess() async throws {
        let transaction = SimpleFINRemoteTransaction(
            id: "bad-amount",
            dateUnixSeconds: 1_782_974_400,
            amount: nil,
            currency: "USD",
            payeeName: "Unreadable",
            notes: nil,
            booked: true,
            accountID: "sfin-1"
        )
        let missingID = SimpleFINRemoteTransaction(
            id: nil,
            dateUnixSeconds: 1_782_974_400,
            amount: "-1.00",
            currency: "USD",
            payeeName: "No Identity",
            notes: nil,
            booked: true,
            accountID: "sfin-1"
        )
        let missingPayee = SimpleFINRemoteTransaction(
            id: "missing-payee",
            dateUnixSeconds: 1_782_974_400,
            amount: "-2.00",
            currency: "USD",
            payeeName: nil,
            notes: "Description only",
            booked: true,
            accountID: "sfin-1"
        )
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [transaction, missingID, missingPayee],
                        startingBalance: nil,
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
        #expect(plan.problems == [
            BankSyncReview.Problem(
                remoteTransactionID: "bad-amount",
                message: "Unreadable amount"
            ),
            BankSyncReview.Problem(
                remoteTransactionID: nil,
                message: "Missing transaction ID"
            ),
            BankSyncReview.Problem(
                remoteTransactionID: "missing-payee",
                message: "Missing payee"
            )
        ])
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.unresolvedProblems) {
            try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        }

        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains { $0.dataset == "transactions" && $0.column == "financial_id" })
        #expect(!messages.contains {
            $0.dataset == "accounts" && $0.row == "savings" && $0.column == "last_sync"
        })
    }

    @Test func staleGenerationDoesNotApply() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(id: "d1", amount: "-10.00", dayID: "20260701", payeeName: "Coffee Shop"),
                            remoteTransaction(id: "d2", amount: "-12.00", dayID: "20260702", payeeName: "Coffee Shop")
                        ],
                        startingBalance: nil,
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

        let stale = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        let fresh = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(fresh.generation != stale.generation)

        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.staleGeneration) {
            try await store.applyBankSyncPlan(stale, budgetID: "group-1")
        }
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let messages = try storedCRDTMessages(at: databaseURL)
        #expect(!messages.contains { $0.dataset == "transactions" && $0.column == "financial_id" })
    }

    // MARK: - Failed download stamps status, not last_sync

    @Test func failedDownloadStampsStatusWithoutLastSync() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount(balance: "0.00")],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    "sfin-1": SimpleFINAccountDownload(
                        transactions: [
                            remoteTransaction(
                                id: "partial-row",
                                amount: "-10.00",
                                dayID: "20260701",
                                payeeName: "Must Not Import"
                            )
                        ],
                        startingBalance: nil,
                        errorType: "provider_error",
                        errorCode: "TIMED_OUT"
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
        #expect(plan.durableStatus == .timedOut)
        #expect(plan.inserts.isEmpty)

        _ = try await store.applyBankSyncPlan(plan, budgetID: "group-1")
        let messages = try storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains {
            $0.dataset == "transactions" && $0.column == "financial_id"
        })
        let stamps = linkedMessages(messages, row: "savings").filter { $0.column == "last_sync" || $0.column == "bank_sync_status" }
        #expect(stamps.map(\.column) == ["bank_sync_status"])
        #expect(stamps.first?.serializedValue == "S:timed-out")
    }

    // MARK: - Open-path provider cache

    @Test func bankSyncSupportIsCachedAndRemoteAccountsReuseIt() async throws {
        let transport = StubSimpleFINTransport(
            support: .configured,
            remoteAccounts: [remoteAccount()]
        )
        let bundle = try await makeBankSyncStore(transport: transport)

        #expect(bundle.store.cachedBankSyncSupport() == nil)
        #expect(try await bundle.store.bankSyncSupport(budgetID: "group-1") == .configured)
        #expect(bundle.store.cachedBankSyncSupport() == .configured)
        #expect(await transport.statusRequests == 1)

        let accounts = try await bundle.store.bankSyncRemoteAccounts(budgetID: "group-1")
        #expect(accounts.map(\.accountID) == ["sfin-1"])
        #expect(await transport.statusRequests == 1)
        #expect(await transport.accountsRequests == 1)
        #expect(bundle.store.cachedBankSyncRemoteAccounts()?.map(\.accountID) == ["sfin-1"])

        let serverURL = bundle.store.openedServerURLString
        bundle.store.reset()
        bundle.store.openedServerURLString = serverURL
        #expect(bundle.store.cachedBankSyncSupport() == nil)
        #expect(bundle.store.cachedBankSyncRemoteAccounts() == nil)
    }
}
