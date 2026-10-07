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

    @Test func theReadWindowWidensByTheFuzzyWindow() {
        #expect(LocalFirstActualStore.monthWidenedWindow(candidateDayIDs: ["20260310", "20260320"]) == 20260303...20260327)
        // Across a month, a year and a leap day.
        #expect(LocalFirstActualStore.monthWidenedWindow(candidateDayIDs: ["20260303"]) == 20260224...20260310)
        #expect(LocalFirstActualStore.monthWidenedWindow(candidateDayIDs: ["20240305"]) == 20240227...20240312)
        #expect(LocalFirstActualStore.monthWidenedWindow(candidateDayIDs: ["20260102"]) == 20251226...20260109)
        // Nothing to bound the read by: read everything.
        #expect(LocalFirstActualStore.monthWidenedWindow(candidateDayIDs: []) == 0...99_999_999)
    }

    private static func compactDay(_ offset: Int) -> String {
        ActualScheduleRecurrence.dayID(from: Date(timeIntervalSince1970: Double(19_900 + offset) * 86_400))
            .replacingOccurrences(of: "-", with: "")
    }

    /// The bounded read (window plus imported ids) is enough for matching: it
    /// plans exactly like the unbounded read, and reads far fewer rows.
    @Test func aScopedReadPlansLikeTheUnboundedRead() async throws {
        var sql = """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            ALTER TABLE transactions ADD COLUMN financial_id TEXT;
            ALTER TABLE transactions ADD COLUMN imported_description TEXT;
            DELETE FROM transactions;
            """
        var rng = SplitMix64(seed: 77)
        for index in 0..<400 {
            let day = Int.random(in: 0..<1_200, using: &rng)
            let imported = Int.random(in: 0..<20, using: &rng) == 0 ? "'bank-\(Int.random(in: 0..<30, using: &rng))'" : "NULL"
            sql += "INSERT INTO transactions (id, acct, date, amount, tombstone, parent_id, is_parent, isChild, financial_id) VALUES ('t-\(index)', 'checking', \(Self.compactDay(day)), \(Int.random(in: -3...3, using: &rng) * 500), 0, NULL, 0, 0, \(imported));\n"
        }
        let database = try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(extraSQL: sql))
        func ordered(_ rows: [BankSyncReconciliation.Existing]) -> [BankSyncReconciliation.Existing] {
            rows.sorted { ($0.dayID, $0.id) < ($1.dayID, $1.id) }
        }
        let all = ordered(try await database.bankSyncExistingRows(accountID: "checking", window: 0...99_999_999))
        #expect(all.count == 400)

        var totalScoped = 0
        for _ in 0..<6 {
            // A file clusters inside a three-week span; some rows carry imported ids.
            let candidates = (0..<30).map { index in
                BankSyncReconciliation.Candidate(
                    financialID: index % 6 == 0 ? "bank-\(index % 30)" : nil,
                    dayID: Self.compactDay(300 + Int.random(in: 0..<21, using: &rng)),
                    amountMinorUnits: [-1_500, -500, 0, 500, 1_000][index % 5],
                    payeeID: nil, payeeName: nil, notes: nil, categoryID: nil, cleared: false, importedPayee: nil
                )
            }
            let scoped = ordered(try await database.bankSyncExistingRows(
                accountID: "checking",
                window: LocalFirstActualStore.monthWidenedWindow(candidateDayIDs: candidates.map(\.dayID)),
                orImportedIDs: Set(candidates.compactMap(\.financialID))
            ))
            let options = ImportReconcileOptions.csv
            let expected = BankSyncReconciliation.plan(candidates: candidates, existing: all, options: options)
            let actual = BankSyncReconciliation.plan(candidates: candidates, existing: scoped, options: options)
            #expect(actual == expected)
            #expect(scoped.count < all.count / 2, "\(scoped.count) of \(all.count)")
            totalScoped += scoped.count
        }
        #expect(totalScoped > 0)
    }

    // MARK: - Off main

    @Test func theReconcilePlanRunsOffTheMainThread() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        let marker = "off-main-plan-\(UUID().uuidString)"

        let outcome = try await bundle.store.reconcileProjectedImport(
            database: database,
            accountID: "checking",
            accountIsOffBudget: false,
            candidateDayIDs: ["20260310"],
            projected: [candidate(id: marker)],
            transferPayeeIDs: [],
            options: .bankSync
        )

        #expect(outcome.plan.inserts.count + outcome.plan.entries.count >= 1)
        #expect(
            MainThreadCallLog.mainThreadCalls(stage: "reconcilePlan", keyContaining: marker).isEmpty,
            "reconcilePlan ran on the main thread"
        )
    }
}
