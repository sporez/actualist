import Testing
@testable import Actualist

@Suite
struct BankSyncMatchReviewTests {
    @Test func detailsListEveryFieldTheMatchWriterCanChange() throws {
        let existing = BankSyncReconciliation.Existing(
            id: "local-1",
            financialID: "old-bank-id",
            dayID: "20260702",
            amountMinorUnits: -1_000,
            payeeID: "old-payee",
            categoryID: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            importedPayee: "Old bank payee",
            isParent: true,
            isChild: false,
            parentID: nil
        )
        let update = BankSyncReconciliation.MatchedUpdate(
            existingID: "local-1",
            financialID: "new-bank-id",
            payeeID: "new-payee",
            categoryID: "groceries",
            importedPayee: "New bank payee",
            notes: "Exact bank note",
            cleared: true,
            childIDs: ["split-a", "split-b"]
        )

        let detail = try #require(BankSyncMatchReview.details(
            updates: [update],
            existing: [existing],
            payeeNames: ["old-payee": "Old Payee", "new-payee": "New Payee"],
            categoryNames: ["groceries": "Groceries"]
        ).first)

        #expect(detail.transactionID == "local-1")
        #expect(detail.currentPayeeName == "Old Payee")
        #expect(detail.dayID == "20260702")
        #expect(detail.amountMinorUnits == -1_000)
        #expect(detail.changes == [
            .init(field: .bankIDReplaced, oldValue: nil, newValue: nil),
            .init(field: .payee, oldValue: "Old Payee", newValue: "New Payee"),
            .init(field: .category, oldValue: nil, newValue: "Groceries"),
            .init(field: .bankPayee, oldValue: "Old bank payee", newValue: "New bank payee"),
            .init(field: .notes, oldValue: nil, newValue: "Exact bank note"),
            .init(field: .cleared, oldValue: "false", newValue: "true"),
            .init(field: .splitChildrenCleared, oldValue: nil, newValue: "2")
        ])
    }
}
