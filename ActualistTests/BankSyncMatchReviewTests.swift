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
            parentID: nil,
            transferID: nil
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

    @Test func detailsListANewPayeeAndAMovedDate() throws {
        let existing = BankSyncReconciliation.Existing(
            id: "local-1", financialID: "bank-1", dayID: "20261007", amountMinorUnits: -1_500,
            payeeID: nil, categoryID: nil, notes: nil, cleared: true, reconciled: false,
            importedPayee: "Market", isParent: false, isChild: false, parentID: nil, transferID: nil
        )
        let update = BankSyncReconciliation.MatchedUpdate(
            existingID: "local-1", financialID: "bank-1", payeeID: nil, categoryID: nil,
            importedPayee: "Market", notes: nil, cleared: true, childIDs: [],
            dayID: "20261010", newPayeeName: "Corner Market"
        )
        let detail = try #require(BankSyncMatchReview.details(
            updates: [update], existing: [existing], payeeNames: [:], categoryNames: [:]
        ).first)
        #expect(detail.changes == [
            .init(field: .newPayee, oldValue: nil, newValue: "Corner Market"),
            .init(field: .date, oldValue: "20261007", newValue: "20261010")
        ])
        #expect(detail.changes.map(BankSyncCopy.matchChangeText) == [
            "Payee: None → Corner Market (new payee)",
            "Date: \(BankSyncCopy.dayText("20261007")) → \(BankSyncCopy.dayText("20261010"))"
        ])
    }
}
