import Foundation
import GRDB
import Testing
@testable import Actualist

/// Writes must reject tombstoned account, category and payee ids (audit 2.11).
extension LocalFirstActualStoreTests {
    private static let tombstonedFixtureSQL = """
        INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
            VALUES ('gone-cat', 'Gone', 'group', 0, 0, 1, 9);
        INSERT INTO category_mapping VALUES ('gone-cat', 'gone-cat');
        INSERT INTO accounts VALUES ('gone-acct', 'Gone Account', 0, 0, 1, 9);
        INSERT INTO payees VALUES ('gone-payee', 'Gone Payee', NULL, 1);
        INSERT INTO payee_mapping VALUES ('gone-payee', 'gone-payee');
        """

    private func liveExistenceDraft(
        account: String = "checking",
        category: String? = "groceries",
        payee: String = "coffee"
    ) throws -> TransactionDraft {
        TransactionDraft(
            accountID: account,
            date: try makeDate(year: 2026, month: 7, day: 8),
            amountMinorUnits: -450,
            payeeID: payee,
            payeeName: "Name",
            categoryID: category,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
    }

    private func expectCreateThrows(_ draft: TransactionDraft, _ label: String) async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.tombstonedFixtureSQL)
        do {
            _ = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
            Issue.record("create accepted a tombstoned \(label)")
        } catch {}
    }

    private func expectUpdateThrows(_ draft: TransactionDraft, _ label: String) async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.tombstonedFixtureSQL)
        do {
            _ = try await store.updateTransactionAndRefresh(
                "txn", with: draft, budgetID: "group-1",
                originalAccountID: "checking", originalMonth: "2026-07"
            ) {}
            Issue.record("update accepted a tombstoned \(label)")
        } catch {}
    }

    @Test func createRejectsTombstonedCategory() async throws {
        try await expectCreateThrows(liveExistenceDraft(category: "gone-cat"), "category")
    }

    @Test func createRejectsTombstonedAccount() async throws {
        try await expectCreateThrows(liveExistenceDraft(account: "gone-acct"), "account")
    }

    @Test func createRejectsTombstonedPayee() async throws {
        try await expectCreateThrows(liveExistenceDraft(payee: "gone-payee"), "payee")
    }

    @Test func updateRejectsTombstonedCategory() async throws {
        try await expectUpdateThrows(liveExistenceDraft(category: "gone-cat"), "category")
    }

    @Test func updateRejectsTombstonedAccount() async throws {
        try await expectUpdateThrows(liveExistenceDraft(account: "gone-acct"), "account")
    }

    @Test func updateRejectsTombstonedPayee() async throws {
        try await expectUpdateThrows(liveExistenceDraft(payee: "gone-payee"), "payee")
    }

    @Test func categorizeRejectsTombstonedCategory() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.tombstonedFixtureSQL)
        let created = try await store.createTransactionAndRefresh(
            liveExistenceDraft(category: nil), budgetID: "group-1"
        ) {}
        let uncategorized = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        let transaction = try #require(
            uncategorized.transactions.first { $0.id == created.changed.transactions.first }
        )
        do {
            _ = try await store.categorizeTransactionAndRefresh(
                transaction, categoryID: "gone-cat", budgetID: "group-1"
            ) {}
            Issue.record("categorize accepted a tombstoned category")
        } catch {}
    }

    @Test func budgetAssignRejectsTombstonedCategory() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.tombstonedFixtureSQL)
        do {
            _ = try await store.assignCategoryBudgetAndRefresh(
                categoryID: "gone-cat", budgeted: 1_000, budgetID: "group-1", month: "2026-07"
            ) {}
            Issue.record("assign accepted a tombstoned category")
        } catch {}
    }

    @Test func moveMoneyRejectsTombstonedCategoryOnEitherSide() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: Self.tombstonedFixtureSQL)
        for (from, to) in [("gone-cat", "groceries"), ("groceries", "gone-cat")] {
            do {
                _ = try await store.moveMoneyAndRefresh(
                    command: BudgetMoveMoneyCommand(fromCategoryID: from, toCategoryID: to, amount: 100),
                    budgetID: "group-1", month: "2026-07"
                ) {}
                Issue.record("move money accepted a tombstoned category (\(from) -> \(to))")
            } catch {}
        }
    }
}
