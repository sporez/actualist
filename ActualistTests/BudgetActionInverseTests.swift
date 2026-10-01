import Foundation
import Testing
@testable import Actualist

@Suite struct BudgetActionInverseTests {
    @Test func assignSummaryCodableRoundTrips() throws {
        let summary = BudgetActionSummary.assign(AssignBudgetAction(
            month: "2026-07",
            categoryID: "groceries",
            before: 50_000,
            after: 62_500
        ))
        try #expect(summary.codableRoundTrip() == summary)
    }

    @Test func moveSummaryCodableRoundTrips() throws {
        let summary = BudgetActionSummary.move(MoveBudgetAction(
            month: "2026-07",
            legs: [
                BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000),
                BudgetMoveLeg(fromCategoryID: nil, toCategoryID: "utilities", amount: 250)
            ]
        ))
        try #expect(summary.codableRoundTrip() == summary)
    }

    @Test func assignInverseCodableRoundTrips() throws {
        let inverse = BudgetActionInverse.assign(AssignBudgetAction(
            month: "2026-08",
            categoryID: "utilities",
            before: 0,
            after: 3_000
        ))
        try #expect(inverse.codableRoundTrip() == inverse)
    }

    @Test func moveInverseCodableRoundTrips() throws {
        let legs = [BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: "dining", amount: 5_000)]
        let inverse = BudgetActionInverse.move(MoveBudgetActionInverse(
            month: "2026-07",
            legs: legs,
            previousBudgeted: ["groceries": 50_000, "dining": 0]
        ))
        try #expect(inverse.codableRoundTrip() == inverse)
    }

    @Test func createTransactionInverseCodableRoundTrips() throws {
        let inverse = BudgetActionInverse.createTransaction(CreateTransactionInverse(
            month: "2026-07",
            primaryTransactionID: "txn-1",
            transactionIDs: ["txn-1", "txn-2"],
            graph: .transfer(pairedID: "txn-2"),
            createdPayeeID: "payee-1",
            learning: BudgetActionLearningSideEffect(
                createdRuleIDs: ["rule-1"],
                updatedRules: []
            )
        ))
        try #expect(inverse.codableRoundTrip() == inverse)
    }

    @Test func transactionBatchSummaryAndInverseCodableRoundTrip() throws {
        let snapshot = TransactionBatchTransactionSnapshot(
            id: "txn-1",
            columns: ["acct", "amount", "category", "cleared", "date", "description", "tombstone"],
            accountID: "checking",
            dateValue: 20260901,
            amount: -450,
            payeeID: nil,
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            reconciled: false,
            tombstone: false,
            isParent: false,
            isChild: false,
            parentID: nil,
            transferID: nil,
            sortOrder: 1,
            splitError: nil,
            startingBalance: false,
            scheduleID: nil,
            importedID: "import-1",
            importedPayee: nil,
            importedDescription: "Market"
        )
        let summary = BudgetActionSummary.transactionBatch(TransactionBatchBudgetAction(
            operation: .categorize,
            selectedCount: 1,
            changedCount: 1,
            clearTarget: nil,
            categoryID: "dining"
        ))
        let inverse = BudgetActionInverse.transactionBatch(TransactionBatchTransactionInverse(
            operation: .categorize,
            selectedTransactionIDs: ["txn-1"],
            beforeSnapshots: [snapshot],
            afterSnapshots: [snapshot],
            learning: .empty
        ))
        try #expect(summary.codableRoundTrip() == summary)
        try #expect(inverse.codableRoundTrip() == inverse)
    }

    @Test func kindsPersistAsDistinctDiscriminators() throws {
        let assign = BudgetActionInverse.assign(AssignBudgetAction(
            month: "2026-07",
            categoryID: "groceries",
            before: 0,
            after: 1
        ))
        let move = BudgetActionInverse.move(MoveBudgetActionInverse(
            month: "2026-07",
            legs: [BudgetMoveLeg(fromCategoryID: "groceries", toCategoryID: nil, amount: 1)],
            previousBudgeted: ["groceries": 1]
        ))
        let assignJSON = try JSONEncoder().encode(assign)
        let moveJSON = try JSONEncoder().encode(move)
        #expect(assignJSON != moveJSON)
        #expect(try JSONDecoder().decode(BudgetActionInverse.self, from: assignJSON) == assign)
        #expect(try JSONDecoder().decode(BudgetActionInverse.self, from: moveJSON) == move)
    }

    @Test func legacyActionLogSummaryAndInverseFixturesStillDecode() throws {
        let summaryJSON = Data(#"{"type":"assign","payload":{"payload":{"month":"2026-07","categoryID":"groceries","before":0,"after":1}}}"#.utf8)
        let inverseJSON = Data(#"{"type":"categorize","payload":{"payload":{"month":"2026-07","items":[],"learning":{"createdRuleIDs":[],"updatedRules":[]}}}}"#.utf8)

        #expect(try JSONDecoder().decode(BudgetActionSummary.self, from: summaryJSON) == .assign(
            AssignBudgetAction(month: "2026-07", categoryID: "groceries", before: 0, after: 1)
        ))
        #expect(try JSONDecoder().decode(BudgetActionInverse.self, from: inverseJSON) == .categorize(
            CategorizeTransactionInverse(month: "2026-07", items: [], learning: .empty)
        ))
    }
}

private extension Encodable where Self: Decodable {
    func codableRoundTrip() throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(self))
    }
}
