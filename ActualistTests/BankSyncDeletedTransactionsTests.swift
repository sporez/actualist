import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct BankSyncDeletedTransactionsTests {
    private let support = LocalFirstActualStoreTests()

    private func fixture(
        preference: String? = "false",
        rules: String = ""
    ) async throws -> (LocalFirstActualStoreTests.OpenedWritableStoreBundle, DatabaseQueue) {
        let remote = SimpleFINRemoteAccount(
            accountID: "bank-account", name: "Checking", balance: "100.00", currency: "USD",
            institution: nil, orgName: "Fixture Bank", orgDomain: "bank.example", orgID: nil
        )
        let transaction = SimpleFINRemoteTransaction(
            id: "bank-transaction", dateUnixSeconds: 1_783_000_000, amount: "-10.00",
            currency: "USD", payeeName: "Coffee Shop", notes: "Downloaded", booked: true,
            accountID: remote.accountID
        )
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [remote.accountID: SimpleFINAccountDownload(
                    transactions: [transaction], startingBalance: 10_000,
                    errorType: nil, errorCode: nil
                )], errorType: nil, errorCode: nil
            )
        )
        let preferenceSQL = preference.map { value in
            """
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER);
            INSERT INTO preferences VALUES ('sync-reimport-deleted-savings', '\(value)', 0);
            """
        } ?? ""
        let bundle = try await support.makeOpenedWritableStoreBundle(
            simpleFINTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [],
            additionalFixtureSQL: preferenceSQL + "\n" + rules + "\n" + LocalFirstActualStoreTests.bankSyncColumnsSQL
        )
        bundle.store.openedServerURLString = "https://sync.example"
        try bundle.keychain.saveActualSyncToken("test-sync-token")
        let database = try bundle.store.requireDatabase(for: "group-1")
        let queue = await database.queue
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")
        return (bundle, queue)
    }

    @Test(arguments: ["false", "true", "missing"])
    func deletedBankIDHonorsAccountPreference(preference: String) async throws {
        let (bundle, queue) = try await fixture(preference: preference == "missing" ? nil : preference)
        try await queue.write { db in
            // Changed date AND amount: deleted IDs must be found outside the fuzzy window.
            try db.execute(sql: """
                INSERT INTO transactions
                    (id, acct, date, amount, tombstone, description, notes, cleared, financial_id)
                VALUES ('deleted', 'savings', 20200101, -9999, 1, 'coffee', 'Keep deleted', 0, 'bank-transaction');
                """)
        }
        let before = try await queue.read { db -> String? in
            try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = 'deleted'")?.description
        }
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        let shouldInsert = preference != "false"
        #expect(plan.inserts.count == (shouldInsert ? 1 : 0))
        #expect(plan.updates.isEmpty)
        #expect(plan.openingBalance?.amountMinorUnits == (shouldInsert ? 11_000 : 10_000))
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let after = try await queue.read { db -> String? in
            try Row.fetchOne(db, sql: "SELECT * FROM transactions WHERE id = 'deleted'")?.description
        }
        #expect(before == after)
        let messages = try support.storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains { $0.dataset == "transactions" && $0.row == "deleted" })
        let repeatSync = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(repeatSync.insertedTransactionIDsByAccount["savings"]?.isEmpty != false)
        let total = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT SUM(amount) FROM transactions WHERE acct = 'savings' AND IFNULL(tombstone, 0) = 0")
        }
        #expect(total == 10_000)
    }

    @Test func deletedExactIDDoesNotClaimUnrelatedLiveFuzzyMatch() async throws {
        let (bundle, queue) = try await fixture()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, tombstone, description, financial_id)
                VALUES ('deleted', 'savings', 20260702, -1000, 1, 'coffee', 'bank-transaction');
                INSERT INTO transactions (id, acct, date, amount, tombstone, description)
                VALUES ('manual', 'savings', 20260702, -1000, 0, 'coffee');
                """)
        }
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.isEmpty)
        #expect(plan.updates.isEmpty)
        #expect(plan.openingBalance == nil)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let messages = try support.storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains { $0.dataset == "transactions" })
    }

    @Test func liveReimportedCopyStillReceivesBankUpdates() async throws {
        let (bundle, queue) = try await fixture()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, tombstone, description, financial_id, cleared)
                VALUES ('deleted', 'savings', 20200101, -9999, 1, 'coffee', 'bank-transaction', 0),
                       ('live', 'savings', 20260702, -1000, 0, 'coffee', 'bank-transaction', 0);
                """)
        }
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.isEmpty)
        #expect(plan.updates.map(\.existingID) == ["live"])
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let messages = try support.storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(messages.contains { $0.dataset == "transactions" && $0.row == "live" && $0.column == "cleared" })
        #expect(!messages.contains { $0.dataset == "transactions" && $0.row == "deleted" })
    }

    @Test(arguments: ["other-account", "different-id", "no-id"])
    func unrelatedTombstoneDoesNotSuppressDownload(kind: String) async throws {
        let (bundle, queue) = try await fixture()
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transactions (id, acct, date, amount, tombstone, description, financial_id)
                    VALUES ('deleted', ?, 20260702, -1000, 1, 'coffee', ?)
                    """,
                arguments: [kind == "other-account" ? "credit" : "savings",
                            kind == "no-id" ? nil : (kind == "different-id" ? "another-id" : "bank-transaction")]
            )
        }
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.count == 1)
        #expect(plan.updates.isEmpty)
    }

    @Test(arguments: [true, false])
    func openingBalanceUsesOnlyFinalRuleInserts(delete: Bool) async throws {
        let action = delete
            ? #"{"op":"delete-transaction","value":""}"#
            : #"{"op":"set","field":"amount","value":-2500,"type":"number"}"#
        let (bundle, queue) = try await fixture(rules: """
            CREATE TABLE rules (id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER);
            INSERT INTO rules VALUES ('rule',
                '[{"field":"imported_payee","op":"is","value":"Coffee Shop","type":"string"}]',
                '[\(action)]', 0);
            """)
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.count == (delete ? 0 : 1))
        #expect(plan.openingBalance?.amountMinorUnits == (delete ? 10_000 : 12_500))
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let total = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT SUM(amount) FROM transactions WHERE acct = 'savings' AND IFNULL(tombstone, 0) = 0")
        }
        #expect(total == 10_000)
    }

    @Test func importDeleteThenForegroundAndBackgroundSyncKeepsTransactionDeleted() async throws {
        let (bundle, queue) = try await fixture()
        let store = bundle.store
        let first = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        _ = try await store.applyBankSyncPlan(first, budgetID: "group-1")
        let database = try store.requireDatabase(for: "group-1")
        let importedID = try #require(try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM transactions WHERE financial_id = 'bank-transaction'")
        })
        let transaction = try #require(try await database.fetchTransactions(accountID: "savings")
            .first { $0.id == importedID })
        _ = try await store.deleteTransactionAndRefresh(transaction, budgetID: "group-1") {}
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let messagesAfterDelete = try support.storedCRDTMessages(at: databaseURL)
            .filter { $0.dataset == "transactions" }

        let repeatPlan = try await store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(repeatPlan.inserts.isEmpty)
        #expect(repeatPlan.updates.isEmpty)
        #expect(repeatPlan.openingBalance == nil)
        _ = try await store.applyBankSyncPlan(repeatPlan, budgetID: "group-1")
        _ = try await store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(try support.storedCRDTMessages(at: databaseURL)
            .filter { $0.dataset == "transactions" } == messagesAfterDelete)
        let rows = try await queue.read { db in
            try Int.fetchAll(db, sql: "SELECT tombstone FROM transactions WHERE financial_id = 'bank-transaction'")
        }
        #expect(rows == [1])
        #expect(try await database.fetchTransactions(accountID: "savings").allSatisfy { $0.id != importedID })
    }

    @Test func syncedPreferenceIsReadAgainOnNextPlan() async throws {
        let (bundle, queue) = try await fixture(preference: "true")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, tombstone, financial_id)
                VALUES ('deleted', 'savings', 20200101, -1000, 1, 'bank-transaction')
                """)
        }
        let first = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(first.inserts.count == 1)
        let database = try bundle.store.requireDatabase(for: "group-1")
        var builder = LocalFirstSyncMessageBuilder()
        let preference = try builder.makeMessage(
            dataset: "preferences", row: "sync-reimport-deleted-savings", column: "value", value: .string("false")
        )
        _ = try await database.applyRemoteSyncMessages([preference])
        let second = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(second.inserts.isEmpty)
        #expect(second.unchangedCount == 1)
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.staleGeneration) {
            try await bundle.store.applyBankSyncPlan(first, budgetID: "group-1")
        }
    }

    @Test(arguments: ["missing-row", "null", "tombstoned"])
    func absentPreferenceValueKeepsUpstreamDefault(kind: String) async throws {
        let (bundle, queue) = try await fixture()
        try await queue.write { db in
            switch kind {
            case "missing-row": try db.execute(sql: "DELETE FROM preferences")
            case "null": try db.execute(sql: "UPDATE preferences SET value = NULL")
            default:
                try db.execute(sql: "UPDATE preferences SET tombstone = 1")
            }
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, tombstone, financial_id)
                VALUES ('deleted', 'savings', 20200101, -1000, 1, 'bank-transaction')
                """)
        }
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.count == 1)
    }

    @Test func deletedIDReadUsesExistingSchemaAliasesAndRejectsInvalidChildren() async throws {
        let (bundle, queue) = try await fixture()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, tombstone, financial_id, isChild)
                VALUES ('deleted', 'savings', 20200101, -1000, 1, 'bank-transaction', 0),
                       ('invalid-child', 'savings', 20200101, -1000, 1, 'invalid', 1);
                ALTER TABLE transactions RENAME COLUMN financial_id TO imported_id;
                ALTER TABLE transactions RENAME COLUMN tombstone TO deleted;
                """)
        }
        let database = try BudgetDatabase(databaseURL: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(try await database.bankSyncSuppressedFinancialIDs(accountID: "savings") == ["bank-transaction"])
    }

    @Test(arguments: ["transactions", "financial_id", "tombstone"])
    func olderSchemaWithoutDeletedBankIdentityHasNoSuppression(missing: String) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "BankSyncSchema-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences VALUES ('sync-reimport-deleted-savings', 'false');
                """)
            if missing != "transactions" {
                let columns = ["id TEXT", "acct TEXT", "date INTEGER", "financial_id TEXT", "tombstone INTEGER"]
                    .filter { !$0.hasPrefix(missing + " ") }.joined(separator: ", ")
                try db.execute(sql: "CREATE TABLE transactions (\(columns))")
            }
        }
        let database = try BudgetDatabase(databaseURL: url)
        #expect(try await database.bankSyncSuppressedFinancialIDs(accountID: "savings").isEmpty)
    }

    @Test func splitRuleOpeningBalanceCountsParentOnce() async throws {
        let (bundle, queue) = try await fixture(rules: """
            CREATE TABLE rules (id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER);
            INSERT INTO rules VALUES ('split',
                '[{"field":"imported_payee","op":"is","value":"Coffee Shop","type":"string"}]',
                '[{"op":"set-split-amount","value":-400,"options":{"method":"fixed-amount","splitIndex":1}},{"op":"set-split-amount","value":0,"options":{"method":"remainder","splitIndex":2}}]', 0);
            """)
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.first?.splits.map(\.amountMinorUnits) == [-400, -600])
        #expect(plan.openingBalance?.amountMinorUnits == 11_000)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let total = try await queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT SUM(amount) FROM transactions
                WHERE acct = 'savings' AND IFNULL(tombstone, 0) = 0 AND IFNULL(is_parent, 0) = 0
                """)
        }
        #expect(total == 10_000)
    }

}
