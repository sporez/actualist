import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func importWalletTransactionsSkipsExistingFinancialIDs() async throws {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let date = try makeDate(year: 2026, month: 7, day: 18)
        let first = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: firstID,
                    amount: Decimal(string: "8.40")!,
                    creditDebitIndicator: .debit,
                    merchantName: "SQ * WALLET CAFE #99",
                    transactionDescription: "SQ * WALLET CAFE #99",
                    transactionDate: date,
                    status: .booked
                )
            )
        )
        let second = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: secondID,
                    amount: Decimal(string: "15.00")!,
                    creditDebitIndicator: .credit,
                    merchantName: "Refund",
                    transactionDescription: "Refund",
                    transactionDate: date,
                    status: .pending
                )
            )
        )

        let firstResult = try await store.importWalletTransactions(
            [first],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let secondResult = try await store.importWalletTransactions(
            [first, second],
            intoAccountID: "checking",
            budgetID: "group-1"
        )

        let existing = try await store.requireDatabase(for: "group-1").existingImportedIDs(accountID: "checking")
        let loaded = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
        let importedCafe = try #require(loaded.transactions.first {
            $0.importedPayee == "SQ * WALLET CAFE #99"
        })
        let importedRefund = try #require(loaded.transactions.first { $0.importedPayee == "Refund" })

        #expect(firstResult == WalletTransactionImportResult(addedCount: 1, matchedCount: 0))
        #expect(secondResult == WalletTransactionImportResult(addedCount: 1, matchedCount: 1))
        #expect(existing == [firstID.uuidString.lowercased(), secondID.uuidString.lowercased()])
        #expect(importedCafe.amount == -840)
        #expect(importedCafe.cleared == .bool(true))
        #expect(importedCafe.payeeName == "Wallet Cafe")
        #expect(importedRefund.amount == 1_500)
        #expect(importedRefund.cleared == .bool(false))
        #expect(loaded.transactions.filter {
            $0.importedPayee == "SQ * WALLET CAFE #99"
        }.count == 1)
    }

    @Test func importWalletTransactionsAppliesMatchingPayeeRule() async throws {
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-cafe-rule',
                '[{"field":"payee_name","op":"is","value":"Rule Cafe"}]',
                '[{"field":"category","op":"set","value":"groceries"}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
                    amount: Decimal(string: "6.25")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Rule Cafe",
                    transactionDescription: "Rule Cafe",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 19),
                    status: .booked
                )
            )
        )

        let result = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let loaded = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
        let imported = try #require(loaded.transactions.first { $0.importedPayee == "Rule Cafe" })

        #expect(result.addedCount == 1)
        #expect(imported.category == "groceries")
        #expect(imported.amount == -625)
    }

    @Test func importWalletTransactionsDropsCategoryOnOffBudgetAccount() async throws {
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-offbudget-rule',
                '[{"field":"payee_name","op":"is","value":"Rule Cafe"}]',
                '[{"field":"category","op":"set","value":"groceries"}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
                    amount: Decimal(string: "6.25")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Rule Cafe",
                    transactionDescription: "Rule Cafe",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 19),
                    status: .booked
                )
            )
        )

        let result = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "tracking",
            budgetID: "group-1"
        )
        let loaded = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("tracking"), query: TransactionFeedQuery()))
        let imported = try #require(loaded.transactions.first { $0.importedPayee == "Rule Cafe" })

        #expect(result.addedCount == 1)
        #expect(imported.category == nil)
        #expect(imported.amount == -625)
    }

    @Test func importWalletTransactionsCreatesTransferWhenRuleSetsAccountPayee() async throws {
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-transfer-payee-rule',
                '[{"field":"payee_name","op":"is","value":"Move To Savings"}]',
                '[{"field":"description","op":"set","value":"xfer-savings","type":"id"}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "abababab-cdcd-efef-aaaa-bbbbbbbbbbbb")!,
                    amount: Decimal(string: "10.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Move To Savings",
                    transactionDescription: "Move To Savings",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 20),
                    status: .booked
                )
            )
        )

        let result = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let checking = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
        let savings = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("savings"), query: TransactionFeedQuery()))
        let source = try #require(checking.transactions.first { $0.importedPayee == "Move To Savings" })
        let destination = try #require(savings.transactions.first { $0.amount == 1_000 })

        #expect(result.addedCount == 1)
        #expect(source.payee == "xfer-savings")
        #expect(source.amount == -1_000)
        #expect(destination.payee == "xfer-checking")
        #expect(destination.account == "savings")
    }

    @Test func importWalletTransactionsAppliesExistingPayeeIDRule() async throws {
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-payee-id-rule',
                '[{"field":"payee","op":"is","value":"coffee","type":"id"}]',
                '[{"field":"category","op":"set","value":"groceries","type":"id"}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "44444444-5555-6666-7777-888888888888")!,
                    amount: Decimal(string: "3.50")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Coffee Shop",
                    transactionDescription: "Coffee Shop",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 22),
                    status: .booked
                )
            )
        )

        let result = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let loaded = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
        let imported = try #require(loaded.transactions.first { $0.importedPayee == "Coffee Shop" })

        #expect(result.addedCount == 1)
        #expect(imported.payee == "coffee")
        #expect(imported.category == "groceries")
    }

    @Test func importWalletTransactionsKeepsRawImportedPayeeForRules() async throws {
        let rawPayee = "SQ * RAW WALLET CAFE #123"
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-raw-payee-rule',
                '[{"field":"imported_payee","op":"is","value":"\(rawPayee)","type":"string"}]',
                '[{"field":"category","op":"set","value":"groceries","type":"id"}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                    amount: Decimal(string: "7.25")!,
                    creditDebitIndicator: .debit,
                    merchantName: rawPayee,
                    transactionDescription: rawPayee,
                    transactionDate: try makeDate(year: 2026, month: 7, day: 20),
                    status: .booked
                )
            )
        )

        _ = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )

        let loaded = try #require(
            store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery())
        )
        let imported = try #require(loaded.transactions.first {
            $0.importedPayee == rawPayee
        })
        #expect(imported.payeeName == "Raw Wallet Cafe")
        #expect(imported.category == "groceries")
    }

    @Test func walletRemoveNotesRuleProducesFinalEmptyNotes() async throws {
        let rawPayee = "WALLET MEMO MERCHANT"
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-remove-notes',
                '[{"field":"imported_payee","op":"is","value":"\(rawPayee)","type":"string"}]',
                '[{"field":"notes","op":"set","value":""}]',
                0
            );
            """)
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
                    amount: Decimal(string: "5.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: rawPayee,
                    transactionDescription: rawPayee,
                    transactionDate: try makeDate(year: 2026, month: 7, day: 20),
                    status: .booked
                )
            )
        )
        var reconcile = WalletTransactionMapper.reconcileCandidate(from: candidate, payeeID: nil)
        reconcile.notes = "Original FinanceKit memo"
        let noteBearingDraft = ImportReconcileProjection.previewDraft(for: reconcile, accountID: "checking")

        let preview = try await store.previewRules(
            for: noteBearingDraft,
            budgetID: "group-1"
        )
        let projected = try #require(BankSyncReconciliation.applyingRulePreview(preview, to: reconcile))

        // A rule that sets notes to '' stores an empty note, as Actual does.
        #expect(preview.notes == "")
        #expect(projected.notes == "")
    }

    @Test func importWalletTransactionsPersistsRuleSplitChildrenAndParentIdentity() async throws {
        let financialID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let store = try await makeOpenedWritableStore(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-split-rule',
                '[{"field":"payee_name","op":"is","value":"Split Cafe"}]',
                '[{"op":"set-split-amount","value":0,"options":{"method":"remainder","splitIndex":1}},{"op":"set","field":"category","value":"groceries","options":{"splitIndex":1}},{"op":"set","field":"notes","value":"child-a","options":{"splitIndex":1}}]',
                0
            );
            """
        )
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: financialID,
                    amount: Decimal(string: "10.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Split Cafe",
                    transactionDescription: "Split Cafe",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 21),
                    status: .booked
                )
            )
        )

        let first = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let second = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )
        let loaded = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
        let parent = try #require(loaded.transactions.first { $0.importedPayee == "Split Cafe" })
        let child = try #require(parent.subtransactions.first)

        #expect(first == WalletTransactionImportResult(addedCount: 1, matchedCount: 0))
        #expect(second == WalletTransactionImportResult(addedCount: 0, matchedCount: 1))
        #expect(parent.isParent)
        #expect(parent.category == nil)
        #expect(parent.importedPayee == "Split Cafe")
        #expect(try await store.requireDatabase(for: "group-1").existingImportedIDs(accountID: "checking") == [financialID.uuidString.lowercased()])
        #expect(parent.subtransactions.count == 1)
        #expect(child.amount == -1_000)
        #expect(child.category == "groceries")
        #expect(child.notes == "child-a")
        #expect(child.importedPayee == nil)
        #expect(loaded.transactions.filter { $0.importedPayee == "Split Cafe" }.count == 1)
    }

    @Test func existingImportedIDsAreScopedToTheAccount() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let candidate = try #require(
            WalletTransactionMapper.map(
                WalletTransactionFields(
                    id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
                    amount: Decimal(string: "4.00")!,
                    creditDebitIndicator: .debit,
                    merchantName: "Scoped",
                    transactionDescription: "Scoped",
                    transactionDate: try makeDate(year: 2026, month: 7, day: 20),
                    status: .booked
                )
            )
        )

        _ = try await store.importWalletTransactions(
            [candidate],
            intoAccountID: "checking",
            budgetID: "group-1"
        )

        let checking = try await store.requireDatabase(for: "group-1").existingImportedIDs(accountID: "checking")
        let credit = try await store.requireDatabase(for: "group-1").existingImportedIDs(accountID: "credit")
        #expect(checking == [candidate.financialID])
        #expect(credit.isEmpty)
    }

    /// A new device gives the same Wallet purchase a new ID. The import matches
    /// the existing row by amount and date (upstream's non-strict synced-account
    /// match) and the row takes the new ID, keeping the user's category.
    @Test func walletImportMatchesTheSamePurchaseUnderANewDeviceID() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let store = bundle.store
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID)).path)
        let oldDeviceID = UUID(uuidString: "09c3ed8a-0000-4000-8000-000000000001")!
        let newDeviceID = UUID(uuidString: "679d5f61-0000-4000-8000-000000000002")!
        let date = try makeDate(year: 2026, month: 10, day: 19)
        func candidate(_ id: UUID) throws -> WalletTransactionCandidate {
            try #require(WalletTransactionMapper.map(WalletTransactionFields(
                id: id,
                amount: Decimal(string: "90.00")!,
                creditDebitIndicator: .debit,
                merchantName: "FIDIUM NNE PMTS",
                transactionDescription: "FIDIUM NNE PMTS",
                transactionDate: date,
                status: .booked
            )))
        }
        _ = try await store.importWalletTransactions(
            [try candidate(oldDeviceID)], intoAccountID: "checking", budgetID: "group-1"
        )
        let original = try #require(
            store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery())?
                .transactions.first { $0.importedPayee == "FIDIUM NNE PMTS" }
        )
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE transactions SET category = 'groceries' WHERE id = ?",
                arguments: [original.id]
            )
        }

        _ = try await store.importWalletTransactions(
            [try candidate(newDeviceID)], intoAccountID: "checking", budgetID: "group-1"
        )

        let rows = try await queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, category, financial_id FROM transactions
                    WHERE acct = 'checking' AND amount = -9000 AND (tombstone IS NULL OR tombstone = 0)
                    """
            ).map { [$0["id"] as String?, $0["category"] as String?, $0["financial_id"] as String?] }
        }
        #expect(rows.count == 1)
        #expect(rows.first == [original.id, "groceries", newDeviceID.uuidString.lowercased()])
    }

    private func walletFields(
        _ id: String,
        amount: String,
        merchant: String,
        day: Int,
        status: WalletTransactionStatus = .booked
    ) throws -> WalletTransactionCandidate {
        let uuid = try #require(UUID(uuidString: id))
        let decimal = try #require(Decimal(string: amount))
        let date = try makeDate(year: 2026, month: 10, day: day)
        return try #require(WalletTransactionMapper.map(WalletTransactionFields(
            id: uuid,
            amount: decimal,
            creditDebitIndicator: .debit,
            merchantName: merchant,
            transactionDescription: merchant,
            transactionDate: date,
            status: status
        )))
    }

    /// Wallet used to skip a known ID, so a pending row never became cleared.
    @Test func walletImportClearsAPendingRowWhenItPosts() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let id = "5a5a5a5a-0000-4000-8000-000000000001"
        let pending = try walletFields(id, amount: "12.00", merchant: "Pending Cafe", day: 17, status: .pending)
        let booked = try walletFields(id, amount: "12.00", merchant: "Pending Cafe", day: 17, status: .booked)

        _ = try await store.importWalletTransactions([pending], intoAccountID: "checking", budgetID: "group-1")
        let result = try await store.importWalletTransactions([booked], intoAccountID: "checking", budgetID: "group-1")

        let rows = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
            .transactions.filter { $0.importedPayee == "Pending Cafe" }
        #expect(result == WalletTransactionImportResult(addedCount: 0, matchedCount: 1))
        #expect(rows.count == 1)
        #expect(rows.first?.cleared == .bool(true))
    }

    /// A transaction the user entered by hand is matched and takes the Wallet
    /// ID instead of being added again.
    @Test func walletImportMatchesAHandEnteredRow() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID)).path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, category, notes, tombstone)
                VALUES ('hand-entered', 'checking', 20261016, -800, 'groceries', 'typed by me', 0)
                """)
        }
        let id = "6b6b6b6b-0000-4000-8000-000000000001"
        let candidate = try walletFields(id, amount: "8.00", merchant: "Podcast", day: 17)

        let result = try await bundle.store.importWalletTransactions(
            [candidate], intoAccountID: "checking", budgetID: "group-1"
        )

        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, category, notes, financial_id FROM transactions
                WHERE acct = 'checking' AND amount = -800 AND (tombstone IS NULL OR tombstone = 0)
                """).map { [$0["id"] as String?, $0["category"] as String?, $0["notes"] as String?, $0["financial_id"] as String?] }
        }
        #expect(result == WalletTransactionImportResult(addedCount: 0, matchedCount: 1))
        #expect(rows == [["hand-entered", "groceries", "typed by me", id]])
    }

    /// Two purchases with the same amount a few days apart, both re-sent under
    /// new IDs, pair one to one by nearest date; nothing is added.
    @Test func walletImportPairsSameAmountPurchasesOneToOne() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.walletImportColumnsSQL)
        let first = try walletFields("7c7c7c7c-0000-4000-8000-000000000001", amount: "19.99", merchant: "Apple", day: 13)
        let second = try walletFields("7c7c7c7c-0000-4000-8000-000000000002", amount: "19.99", merchant: "Apple", day: 17)
        _ = try await store.importWalletTransactions([first, second], intoAccountID: "checking", budgetID: "group-1")

        let resent = [
            try walletFields("8d8d8d8d-0000-4000-8000-000000000001", amount: "19.99", merchant: "Apple", day: 13),
            try walletFields("8d8d8d8d-0000-4000-8000-000000000002", amount: "19.99", merchant: "Apple", day: 17),
        ]
        let result = try await store.importWalletTransactions(resent, intoAccountID: "checking", budgetID: "group-1")

        let rows = try #require(store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
            .transactions.filter { $0.amount == -1_999 }
        #expect(result == WalletTransactionImportResult(addedCount: 0, matchedCount: 2))
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.date)) == ["2026-10-13", "2026-10-17"])
    }

    /// Upstream saves imports without `learnCategories`; a rule-set category on
    /// an imported row is not a user categorization.
    @Test func walletImportDoesNotLearnFromARuleCategory() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
            \(Self.walletImportColumnsSQL)
            CREATE TABLE rules (
                id TEXT PRIMARY KEY,
                conditions TEXT,
                actions TEXT,
                tombstone INTEGER
            );
            INSERT INTO rules VALUES (
                'wallet-learning-rule',
                '[{"field":"imported_payee","op":"is","value":"LEARN CAFE","type":"string"}]',
                '[{"field":"category","op":"set","value":"groceries","type":"id"}]',
                0
            );
            """
        )
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID)).path)
        let candidate = try walletFields("9e9e9e9e-0000-4000-8000-000000000001", amount: "4.00", merchant: "LEARN CAFE", day: 18)

        let result = try await bundle.store.importWalletTransactions(
            [candidate], intoAccountID: "checking", budgetID: "group-1"
        )

        let imported = try #require(bundle.store.cachedTransactions(budgetID: "group-1", scope: .account("checking"), query: TransactionFeedQuery()))
            .transactions.first { $0.importedPayee == "LEARN CAFE" }
        let ruleIDs = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM rules WHERE tombstone IS NULL OR tombstone = 0")
        }
        #expect(result.addedCount == 1)
        #expect(imported?.category == "groceries")
        #expect(ruleIDs == ["wallet-learning-rule"])
    }

    static let walletImportColumnsSQL = """
        ALTER TABLE transactions ADD COLUMN financial_id TEXT;
        ALTER TABLE transactions ADD COLUMN imported_description TEXT;
        ALTER TABLE transactions ADD COLUMN sort_order REAL;
        """
}
