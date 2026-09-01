import Foundation
import Testing
@testable import Actualist

struct TransactionSplitEditorStateTests {
    @Test func loadKeepsUncategorizedZeroMixedSignAndTransferChildrenInOrder() {
        var state = TransactionSplitEditorState()
        state.load(from: Self.family(
            amount: -100,
            children: [
                Self.child(id: "a", amount: -110, payee: "payee-a", payeeName: "Child A", category: "groceries", notes: "note a"),
                Self.child(id: "b", amount: 10, payee: nil, payeeName: nil, category: nil, notes: "inflow"),
                Self.child(id: "c", amount: 0, payee: nil, category: nil, notes: "zero child"),
                Self.child(id: "d", amount: -60, payee: "transfer-payee", payeeName: "SPLIT · Transfer", category: nil, notes: "transfer child")
            ]
        ))

        #expect(state.isSplit)
        #expect(state.splitRows.map(\.transactionID) == ["a", "b", "c", "d"])
        #expect(state.splitRows.map(\.amountMinorUnits) == [-110, 10, 0, -60])
        #expect(state.splitRows.map(\.categoryID) == ["groceries", nil, nil, nil])
        #expect(state.splitRows.map(\.payeeID) == ["payee-a", nil, nil, "transfer-payee"])
        #expect(state.splitRows.map(\.notes) == ["note a", "inflow", "zero child", "transfer child"])
    }

    @Test func loadThenDraftsAreLosslessForNullableChildFields() {
        var state = TransactionSplitEditorState()
        state.load(from: Self.family(
            amount: -70,
            children: [
                Self.child(id: "a", amount: -40, payee: "payee-a", category: "groceries", notes: "keep"),
                Self.child(id: "b", amount: -30, payee: nil, category: nil, notes: nil)
            ]
        ))

        let drafts = state.splitDrafts()
        #expect(drafts.map(\.id) == ["a", "b"])
        #expect(drafts.map(\.amountMinorUnits) == [-40, -30])
        #expect(drafts.map(\.categoryID) == ["groceries", nil])
        #expect(drafts.map(\.payeeID) == [.value("payee-a"), .value(nil)])
        #expect(drafts.map(\.notes) == [.value("keep"), .value(nil)])
        #expect(drafts.map(\.sortOrder) == [.omitted, .omitted])
    }

    @Test func convertToSplitCreatesTwoInheritedZeroChildren() {
        var state = TransactionSplitEditorState()
        state.convertToSplit(
            parentPayeeID: "store",
            parentPayeeName: "Corner Store",
            parentCategoryID: "groceries",
            parentCategoryName: "Groceries"
        )

        #expect(state.isSplit)
        #expect(state.splitRows.count == 2)
        #expect(Set(state.splitRows.map(\.payeeID)) == ["store"])
        #expect(Set(state.splitRows.map(\.categoryID)) == ["groceries"])
        #expect(state.splitRows.map(\.amountMinorUnits) == [0, 0])
        #expect(state.remainingCents(parentSignedAmount: -1234) == -1234)
    }

    @Test func editingOneChildLeavesSiblingFieldsUnchanged() {
        var state = TransactionSplitEditorState()
        state.replaceChildren([
            Self.row(id: "a", transactionID: "child-1", amount: -40, categoryID: "groceries", notes: "a"),
            Self.row(id: "b", transactionID: "child-2", amount: -60, categoryID: "utilities", notes: "b")
        ])

        state.setNotes(id: "a", notes: "changed")
        state.setAmountDigits(id: "a", value: "55", defaultNegative: true)

        #expect(state.splitRows.map(\.notes) == ["changed", "b"])
        #expect(state.splitRows.map(\.amountMinorUnits) == [-55, -60])
        #expect(state.splitRows.map(\.categoryID) == ["groceries", "utilities"])
    }

    @Test func removingFromTwoRowSplitCollapsesToSurvivor() {
        var state = TransactionSplitEditorState()
        state.replaceChildren([
            Self.row(id: "services", amount: -500, categoryID: "services", categoryName: "Services"),
            Self.row(id: "phone", amount: -734, categoryID: "phone", categoryName: "Phone")
        ])

        let collapse = state.removeChild(id: "services")

        #expect(!state.isSplit)
        #expect(state.splitRows.isEmpty)
        #expect(collapse?.categoryID == "phone")
        #expect(collapse?.categoryName == "Phone")
    }

    @Test func mismatchDoesNotBlockValidationAndAutoDistributeFixesSignedTotal() throws {
        var state = TransactionSplitEditorState()
        state.replaceChildren([
            Self.row(id: "first", amount: -500),
            Self.row(id: "second", amount: -600)
        ])

        #expect(state.validate(parentSignedAmount: -1234) == .valid)
        #expect(state.pendingMismatch == TransactionSplitMismatch(transactionTotal: -1234, splitTotal: -1100))

        try state.autoDistribute(parentSignedAmount: -1234)

        #expect(state.checkedSplitTotalCents == -1234)
        #expect(state.pendingMismatch == nil)
    }

    @Test func splitValidationDetectsOverflowWithoutTrapping() {
        var state = TransactionSplitEditorState()
        state.replaceChildren([
            Self.row(id: "first", amount: Int.max),
            Self.row(id: "second", amount: 1)
        ])

        #expect(state.validate(parentSignedAmount: 1) == .overflow)
    }

    @Test func parentWithOneChildStillLoadsAsSplit() {
        var state = TransactionSplitEditorState()
        state.load(from: Self.family(
            amount: -50,
            children: [Self.child(id: "only", amount: -50, category: "groceries")]
        ))

        #expect(state.isSplit)
        #expect(state.splitRows.count == 1)
    }

    private static func family(
        amount: Int,
        children: [ActualTransaction]
    ) -> ActualTransaction {
        ActualTransaction(
            id: "parent",
            account: "checking",
            date: "2026-08-05",
            amount: amount,
            payee: nil,
            payeeName: nil,
            importedPayee: "imported-source",
            category: nil,
            notes: "parent note",
            cleared: .bool(true),
            reconciled: false,
            subtransactions: children,
            isParent: true
        )
    }

    private static func child(
        id: String,
        amount: Int,
        payee: String? = nil,
        payeeName: String? = nil,
        category: String? = nil,
        notes: String? = nil
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
            date: "2026-08-05",
            amount: amount,
            payee: payee,
            payeeName: payeeName,
            importedPayee: nil,
            category: category,
            notes: notes,
            cleared: .bool(true),
            isChild: true,
            parentID: "parent"
        )
    }

    private static func row(
        id: String,
        transactionID: String? = nil,
        amount: Int,
        categoryID: String? = nil,
        categoryName: String? = nil,
        notes: String? = nil
    ) -> TransactionSplitEditorRow {
        TransactionSplitEditorRow(
            id: id,
            transactionID: transactionID,
            amountMinorUnits: amount,
            categoryID: categoryID,
            categoryName: categoryName ?? categoryID,
            payeeID: nil,
            payeeName: nil,
            notes: notes,
            isTransfer: false
        )
    }
}
