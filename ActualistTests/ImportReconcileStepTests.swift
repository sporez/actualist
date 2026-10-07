import Foundation
import Testing
@testable import Actualist

/// The shared import reconcile step (main-to-dev 3.2): rule projection and the
/// widened read the Bank Sync and CSV callers both use.
@MainActor
struct ImportReconcileStepTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func candidate(
        id: String? = "bank-1", day: String = "20260310", amount: Int = -1_000, payee: String? = "payee-a"
    ) -> BankSyncReconciliation.Candidate {
        BankSyncReconciliation.Candidate(
            financialID: id, dayID: day, amountMinorUnits: amount, payeeID: payee, payeeName: "Sample Market",
            notes: "memo", categoryID: nil, cleared: true, importedPayee: "Sample Market"
        )
    }

    // MARK: - Projection

    @Test func previewDraftCarriesWhatRulesEvaluate() {
        var source = candidate()
        source.categoryID = "cat-1"
        let draft = ImportReconcileProjection.previewDraft(for: source, accountID: "checking")
        #expect(draft.accountID == "checking")
        #expect(draft.amountMinorUnits == -1_000)
        #expect(draft.payeeID == "payee-a")
        #expect(draft.payeeName == "Sample Market")
        #expect(draft.categoryID == "cat-1")
        #expect(draft.notes == "memo")
        #expect(draft.importedPayee == "Sample Market")
        #expect(ActualDateOnly.dayID(from: draft.date, timeZone: .autoupdatingCurrent) == "2026-03-10")
    }

    @Test func projectionKeepsDropsAndRefusesInInputOrder() {
        let candidates = [
            candidate(id: "keep"), candidate(id: "delete"), candidate(id: "move"), candidate(id: "schedule"),
        ]
        let previews = [
            TransactionRulePreview(categoryID: "cat-1", notes: "memo", payeeID: "payee-b"),
            TransactionRulePreview(categoryID: nil, notes: "memo", deletesTransaction: true),
            TransactionRulePreview(categoryID: nil, notes: "memo", accountID: "savings"),
            TransactionRulePreview(categoryID: nil, notes: "memo", accountID: "checking", scheduleID: "sched-1"),
        ]
        let result = ImportReconcileProjection.project(
            candidates: candidates, previews: previews, accountID: "checking", accountIsOffBudget: false
        )
        #expect(result.sources == [0, 3])
        #expect(result.movedSources == [2])
        #expect(result.candidates.map(\.financialID) == ["keep", "schedule"])
        #expect(result.candidates[0].payeeID == "payee-b")
        #expect(result.candidates[0].categoryID == "cat-1")
        #expect(result.candidates[1].scheduleID == "sched-1")
    }

    @Test func projectionStripsTheCategoryFromAnOffBudgetAccount() {
        let result = ImportReconcileProjection.project(
            candidates: [candidate()],
            previews: [TransactionRulePreview(categoryID: "cat-1", notes: "memo")],
            accountID: "tracking",
            accountIsOffBudget: true
        )
        #expect(result.candidates.first?.categoryID == nil)
    }

    @Test func aRuleThatSetsClearedMakesItExplicit() {
        var unspecified = candidate()
        unspecified.clearedIsExplicit = false
        let result = ImportReconcileProjection.project(
            candidates: [unspecified, unspecified],
            previews: [
                TransactionRulePreview(categoryID: nil, notes: "memo", cleared: false),
                TransactionRulePreview(categoryID: nil, notes: "memo"),
            ],
            accountID: "checking",
            accountIsOffBudget: false
        )
        #expect(result.candidates.map(\.clearedIsExplicit) == [true, false])
        #expect(result.candidates.map(\.cleared) == [false, true])
    }

    // MARK: - Widened read

    private func database(_ rows: String) throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            ALTER TABLE transactions ADD COLUMN financial_id TEXT;
            ALTER TABLE transactions ADD COLUMN imported_description TEXT;
            DELETE FROM transactions;
            \(rows)
            """))
    }

    @Test func existingRowsJoinTheWindowWhenTheyCarryAnImportedID() async throws {
        let database = try database("""
            INSERT INTO transactions (id, acct, date, amount, tombstone, parent_id, is_parent, isChild, financial_id) VALUES
              ('t-near', 'checking', 20260310, -1000, 0, NULL, 0, 0, 'near-id'),
              ('t-far-id', 'checking', 20250101, -1000, 0, NULL, 0, 0, 'bank-far'),
              ('t-far-plain', 'checking', 20250102, -1000, 0, NULL, 0, 0, NULL),
              ('t-other-account', 'savings', 20250103, -1000, 0, NULL, 0, 0, 'bank-far');
            """)
        let window = 20260301...20260331
        let plain = try await database.bankSyncExistingRows(accountID: "checking", window: window)
        #expect(plain.map(\.id) == ["t-near"])

        let widened = try await database.bankSyncExistingRows(
            accountID: "checking", window: window, orImportedIDs: ["bank-far", "no-such-id"]
        )
        #expect(Set(widened.map(\.id)) == ["t-near", "t-far-id"])

        let inside = try await database.bankSyncExistingRows(
            accountID: "checking", window: window, orImportedIDs: ["near-id"]
        )
        #expect(inside.map(\.id) == ["t-near"])
    }

    @Test func deletedIDsAreSuppressedOnlyWhenTheOptionOrPreferenceSaysSo() async throws {
        let database = try database("""
            INSERT INTO transactions (id, acct, date, amount, tombstone, parent_id, is_parent, isChild, financial_id) VALUES
              ('t-gone', 'checking', 20260310, -1000, 1, NULL, 0, 0, 'gone-id'),
              ('t-live', 'checking', 20260311, -1000, 0, NULL, 0, 0, 'live-id');
            """)
        // Upstream's default is to re-import deleted rows.
        #expect(try await database.bankSyncSuppressedFinancialIDs(accountID: "checking") == [])
        #expect(try await database.bankSyncSuppressedFinancialIDs(
            accountID: "checking", ignoringPreference: true
        ) == ["gone-id"])
    }
}
