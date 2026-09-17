import Foundation
import GRDB
import Testing
@testable import Actualist

/// Bank Sync must not create or update learned payee→category rules. Manual
/// categorization still learns through the existing transaction write path.
@MainActor
struct BankSyncCategoryLearningTests {
    private let support = LocalFirstActualStoreTests()
    private func learningSQL(importRule: Bool, extraTransactions: String = "") -> String {
        """
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER);
        INSERT INTO preferences VALUES ('learn-categories', 'true', 0);
        CREATE TABLE rules (
            id TEXT PRIMARY KEY,
            conditions TEXT,
            actions TEXT,
            tombstone INTEGER
        );
        \(importRule ? """
        INSERT INTO rules VALUES (
            'import-category',
            '[{"field":"imported_payee","op":"is","value":"Coffee Shop","type":"string"}]',
            '[{"field":"category","op":"set","value":"groceries","type":"id"}]',
            0
        );
        """ : "")
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
        VALUES ('hist-1', 'savings', 20260301, -900, 'groceries', 0, 'coffee', NULL, 1, 0);
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
        VALUES ('hist-2', 'savings', 20260302, -800, 'groceries', 0, 'coffee', NULL, 1, 0);
        \(extraTransactions)
        """
    }

    private func linkedLearningStore(
        additionalFixtureSQL: String
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let remote = support.remoteAccount(balance: "0.00")
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [
                    remote.accountID: SimpleFINAccountDownload(
                        transactions: [
                            support.remoteTransaction(
                                id: "learn-1",
                                amount: "-10.00",
                                dayID: "20260304",
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
        let bundle = try await support.makeOpenedWritableStoreBundle(
            simpleFINTransportFactory: { _ in transport },
            additionalFixtureSQL: additionalFixtureSQL + "\n"
                + LocalFirstActualStoreTests.bankSyncColumnsSQL + """
                ALTER TABLE payees ADD COLUMN learn_categories INTEGER DEFAULT 1;
                """
        )
        bundle.store.openedServerURLString = "https://sync.example"
        try bundle.keychain.saveActualSyncToken("test-sync-token")
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")
        return bundle
    }

    private func learnedCoffeeRules(in bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) async throws -> [ManagedRule] {
        let database = try bundle.store.requireDatabase(for: "group-1")
        return try await database.fetchRules().filter { $0.payeeIDs.contains("coffee") }
    }

    @Test func bankSyncRuleCategorizedInsertDoesNotLearn() async throws {
        let bundle = try await linkedLearningStore(additionalFixtureSQL: learningSQL(importRule: true))
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.inserts.first?.categoryID == "groceries")
        #expect(plan.problems.isEmpty)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        #expect(try await learnedCoffeeRules(in: bundle).isEmpty)
        let messages = try support.storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains { $0.dataset == "rules" })
    }

    @Test func bankSyncUncategorizedInsertDoesNotLearn() async throws {
        let bundle = try await linkedLearningStore(additionalFixtureSQL: learningSQL(importRule: false))
        let plan = try await bundle.store.downloadBankSyncPlan(
            accountID: "savings",
            budgetID: "group-1"
        )
        #expect(plan.inserts.first?.categoryID == nil)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        #expect(try await learnedCoffeeRules(in: bundle).isEmpty)
    }

    @Test func backgroundBankSyncDoesNotWriteLearnedRules() async throws {
        let bundle = try await linkedLearningStore(additionalFixtureSQL: learningSQL(importRule: true))
        _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(try await learnedCoffeeRules(in: bundle).isEmpty)
        let messages = try support.storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        #expect(!messages.contains { $0.dataset == "rules" })
    }

    @Test func manualCategorizationStillLearns() async throws {
        let bundle = try await linkedLearningStore(
            additionalFixtureSQL: learningSQL(
                importRule: false,
                extraTransactions: """
                    INSERT INTO transactions
                        (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
                    VALUES ('manual-1', 'savings', 20260305, -700, NULL, 0, 'coffee', NULL, 0, 0);
                    """
            )
        )
        let database = try bundle.store.requireDatabase(for: "group-1")
        let transaction = try #require(
            try await database.fetchTransactions(accountID: "savings")
                .first { $0.id == "manual-1" }
        )
        _ = try await bundle.store.categorizeTransactionAndRefresh(
            transaction,
            categoryID: "groceries",
            budgetID: "group-1",
            didUpdate: {}
        )
        let learned = try #require(try await learnedCoffeeRules(in: bundle).first)
        #expect(learned.draft?.actions.first?.value == .string("groceries"))
    }
}
