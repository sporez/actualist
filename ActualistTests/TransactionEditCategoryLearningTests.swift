import Foundation
import GRDB
import Testing
@testable import Actualist

/// Learned payee→category rules follow loot-core's `batchUpdateTransactions`
/// with `learnCategories`: only an add with a category or an update whose diff
/// sets a category learns. Editing other fields must not write rules.
@MainActor
struct TransactionEditCategoryLearningTests {
    private let support = LocalFirstActualStoreTests()

    private func fixtureSQL(editCategory: String?) -> String {
        let category = editCategory.map { "'\($0)'" } ?? "NULL"
        return """
        CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT, tombstone INTEGER);
        INSERT INTO preferences VALUES ('learn-categories', 'true', 0);
        CREATE TABLE rules (id TEXT PRIMARY KEY, conditions TEXT, actions TEXT, tombstone INTEGER);
        ALTER TABLE payees ADD COLUMN learn_categories INTEGER DEFAULT 1;
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
        VALUES ('hist-1', 'savings', 20260301, -900, 'groceries', 0, 'coffee', NULL, 1, 0);
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
        VALUES ('hist-2', 'savings', 20260302, -800, 'groceries', 0, 'coffee', NULL, 1, 0);
        INSERT INTO transactions
            (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
        VALUES ('edit-1', 'savings', 20260305, -700, \(category), 0, 'coffee', NULL, 0, 0);
        """
    }

    private func draft(category: String?, notes: String?, day: Int = 5) throws -> TransactionDraft {
        TransactionDraft(
            accountID: "savings",
            date: try support.makeDate(year: 2026, month: 3, day: day),
            amountMinorUnits: -700,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: category,
            notes: notes,
            cleared: false,
            isTransfer: false
        )
    }

    private func edit(
        category: String?,
        notes: String?,
        startingCategory: String?
    ) async throws -> (rules: [ManagedRule], ruleMessages: [ActualSyncDecodedMessage]) {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: fixtureSQL(editCategory: startingCategory)
        )
        _ = try await bundle.store.updateTransactionAndRefresh(
            "edit-1",
            with: try draft(category: category, notes: notes),
            budgetID: "group-1",
            originalAccountID: "savings",
            originalMonth: "2026-03"
        ) {}
        return try await outcome(of: bundle)
    }

    private func outcome(
        of bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
    ) async throws -> (rules: [ManagedRule], ruleMessages: [ActualSyncDecodedMessage]) {
        let database = try bundle.store.requireDatabase(for: "group-1")
        let rules = try await database.fetchRules().filter { $0.payeeIDs.contains("coffee") }
        let messages = try support.storedCRDTMessages(at: bundle.fileManager.databaseURL(fileID: "file-1"))
        return (rules, messages.filter { $0.dataset == "rules" })
    }

    @Test func notesOnlyEditOfCategorizedTransactionWritesNoRule() async throws {
        let result = try await edit(category: "groceries", notes: "added note", startingCategory: "groceries")
        #expect(result.rules.isEmpty)
        #expect(result.ruleMessages.isEmpty)
    }

    @Test func clearingTheCategoryWritesNoRule() async throws {
        let result = try await edit(category: nil, notes: nil, startingCategory: "groceries")
        #expect(result.ruleMessages.isEmpty)
    }

    @Test func settingTheCategoryLearnsARule() async throws {
        let result = try await edit(category: "groceries", notes: nil, startingCategory: nil)
        let learned = try #require(result.rules.first)
        #expect(learned.draft?.actions.first?.value == .string("groceries"))
    }

    @Test func changingTheCategoryWithNotesUnchangedStillLearns() async throws {
        let result = try await edit(category: "groceries", notes: nil, startingCategory: "dining")
        #expect(result.rules.count == 1)
    }

    @Test func addingATransactionWithACategoryLearnsARule() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: fixtureSQL(editCategory: "groceries")
        )
        let newDraft = try draft(category: "groceries", notes: nil, day: 6)
        _ = try await bundle.store.createTransactionAndRefresh(newDraft, budgetID: "group-1") {}
        let result = try await outcome(of: bundle)
        #expect(result.rules.count == 1)
    }

    @Test func addingATransactionWithoutACategoryWritesNoRule() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: fixtureSQL(editCategory: "groceries")
        )
        let newDraft = try draft(category: nil, notes: nil, day: 6)
        _ = try await bundle.store.createTransactionAndRefresh(newDraft, budgetID: "group-1") {}
        #expect(try await outcome(of: bundle).ruleMessages.isEmpty)
    }
}
