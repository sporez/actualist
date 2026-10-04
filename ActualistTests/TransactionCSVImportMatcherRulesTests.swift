import Foundation
import Testing
@testable import Actualist

/// Matched-row fill rules that CSV import shares with Bank Sync
/// (mistakes.md 2026-09-16): transfer legs, split parents and off-budget
/// accounts never take a budget category, and a transfer payee never lands on
/// a non-transfer row. Upstream (`reconcileTransactions`, loot-core
/// `sync.ts` 675-735) fills payee, category, notes and cleared with
/// `existing || incoming` and overwrites imported_payee and imported_id.
struct TransactionCSVImportMatcherRulesTests {
    private let context = TransactionCSVImportMatchContext(
        payeeIDByName: ["sample market": "payee-a", "to savings": "payee-transfer"],
        transferPayeeIDs: ["payee-transfer"],
        categoryIDByName: ["groceries": "cat-groceries"]
    )

    private func candidate(
        payeeID: String? = "payee-a",
        categoryID: String? = nil,
        isParent: Bool = false,
        transferID: String? = nil,
        accountOffBudget: Bool = false,
        importedPayee: String? = "Sample Market"
    ) -> TransactionCSVImportCandidate {
        TransactionCSVImportCandidate(
            id: "existing-1",
            importedID: nil,
            payeeID: payeeID,
            categoryID: categoryID,
            notes: nil,
            cleared: false,
            importedPayee: importedPayee,
            amountMinorUnits: -1_234,
            dateText: "2026-09-27",
            reconciled: false,
            isParent: isParent,
            transferID: transferID,
            accountOffBudget: accountOffBudget
        )
    }

    private func row(payee: String = "Sample Market", category: String? = "Groceries") -> TransactionCSVImportRow {
        TransactionCSVImportRow(
            id: "csv-row-1",
            sourceLine: 1,
            dateText: "2026-09-27",
            date: TransactionCSVImportMapper.dayDate(fromISO: "2026-09-27")!,
            amountMinorUnits: -1_234,
            payeeName: payee,
            notes: nil,
            categoryName: category,
            cleared: nil,
            importedID: nil
        )
    }

    private func disposition(
        _ row: TransactionCSVImportRow,
        _ candidate: TransactionCSVImportCandidate
    ) -> TransactionCSVImportDisposition {
        TransactionCSVImportMatcher.match(rows: [row], candidates: [candidate], context: context)[0]
    }

    @Test func ordinaryUncategorizedMatchStillTakesTheFileCategory() {
        guard case .update(let plan) = disposition(row(), candidate()) else {
            Issue.record("expected an update")
            return
        }
        #expect(plan.categoryID == "cat-groceries")
    }

    @Test func transferLegGetsNoCategoryWrite() {
        #expect(disposition(row(), candidate(transferID: "other-leg")) == .ignored)
    }

    @Test func splitParentGetsNoCategoryWrite() {
        #expect(disposition(row(), candidate(isParent: true)) == .ignored)
    }

    @Test func offBudgetMatchGetsNoCategoryWrite() {
        #expect(disposition(row(), candidate(accountOffBudget: true)) == .ignored)
    }

    @Test func nilPayeeIsNotFilledWithATransferPayee() {
        // Tier 3 matches on amount and date alone, so the transfer payee
        // resolves against a row that has no payee.
        #expect(disposition(row(payee: "To Savings", category: nil), candidate(payeeID: nil))
            == .update(TransactionCSVImportUpdatePlan(
                existingTransactionID: "existing-1",
                payeeID: nil,
                categoryID: nil,
                notes: nil,
                cleared: nil,
                importedPayee: "To Savings",
                importedID: nil
            )))
    }

    @Test func nilPayeeStillTakesAnOrdinaryPayee() {
        guard case .update(let plan) = disposition(row(category: nil), candidate(payeeID: nil)) else {
            Issue.record("expected an update")
            return
        }
        #expect(plan.payeeID == "payee-a")
    }

    @Test func transferLegWithNoPayeeKeepsItNil() {
        guard case .update(let plan) = disposition(
            row(category: nil),
            candidate(payeeID: nil, transferID: "other-leg", importedPayee: nil)
        ) else {
            Issue.record("expected an update")
            return
        }
        #expect(plan.payeeID == nil)
    }

    // MARK: - Tier-1 imported_id is an exact match (upstream sync.ts 845-857)

    @Test func importedIDMatchingIsCaseSensitive() {
        let existing = TransactionCSVImportCandidate(
            id: "existing-1",
            importedID: "a1",
            payeeID: "payee-a",
            categoryID: nil,
            notes: nil,
            cleared: false,
            importedPayee: "Sample Market",
            amountMinorUnits: -1_234,
            dateText: "2026-09-27",
            reconciled: false,
            isParent: false,
            transferID: nil,
            accountOffBudget: false
        )
        let upper = TransactionCSVImportRow(
            id: "csv-row-1",
            sourceLine: 1,
            dateText: "2026-09-27",
            date: TransactionCSVImportMapper.dayDate(fromISO: "2026-09-27")!,
            amountMinorUnits: -1_234,
            payeeName: "Sample Market",
            notes: nil,
            categoryName: nil,
            cleared: nil,
            importedID: "A1"
        )
        // Both rows carry an imported_id, so strict id checking also blocks
        // the fuzzy tiers: "A1" does not match "a1" at all.
        #expect(TransactionCSVImportMatcher.match(rows: [upper], candidates: [existing], context: context)
            == [.insert(isTransfer: false)])
        let exact = TransactionCSVImportRow(
            id: "csv-row-2",
            sourceLine: 2,
            dateText: "2026-09-27",
            date: upper.date,
            amountMinorUnits: -1_234,
            payeeName: "Sample Market",
            notes: nil,
            categoryName: nil,
            cleared: nil,
            importedID: "a1"
        )
        #expect(TransactionCSVImportMatcher.match(rows: [exact], candidates: [existing], context: context)
            == [.ignored])
    }
}
