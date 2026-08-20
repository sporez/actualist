import Foundation
import Testing
@testable import Actualist

struct TransactionEditorCategoryStateTests {
    @Test func splitSelectionTransitionsFromSingleToCommittedSplit() {
        var state = TransactionEditorCategoryState(categoryID: "services", fallbackName: "Services")

        state.beginSplitSelection()
        state.toggleSplitCategory(id: "phone", name: "Phone")

        #expect(state.isSelectingSplit)
        #expect(state.selectedCategoryID == nil)
        #expect(state.splitRows.map(\.categoryID) == ["services", "phone"])

        state.finalizeSplitSelection()

        #expect(!state.isSelectingSplit)
        #expect(state.isSplit)
        #expect(state.summaryName == "Services, Phone")
    }

    @Test func emptySplitSelectionRestoresOriginalSingleCategory() {
        var state = TransactionEditorCategoryState(categoryID: "services", fallbackName: "Services")

        state.beginSplitSelection()
        state.toggleSplitCategory(id: "services", name: "Services")
        state.finalizeSplitSelection()

        #expect(state.selectedCategoryID == "services")
        #expect(state.selectedCategoryFallbackName == "Services")
        #expect(state.splitRows.isEmpty)
    }

    @Test func removingFromTwoRowSplitCollapsesToSurvivingCategory() {
        var state = Self.splitState(firstAmount: "500", secondAmount: "734")

        state.removeSplit(rowID: "services")

        #expect(!state.isSplit)
        #expect(state.selectedCategoryID == "phone")
        #expect(state.selectedCategoryFallbackName == "Phone")
    }

    @Test func mismatchCanBeRecordedAndAutoDistributed() throws {
        var state = Self.splitState(firstAmount: "500", secondAmount: "600")

        #expect(
            state.validate(transactionTotal: 1_234, submitsAsTransfer: false)
                == .mismatch(TransactionSplitMismatch(transactionTotal: 1_234, splitTotal: 1_100))
        )

        try state.autoDistributeMismatch(transactionTotal: 1_234)

        #expect(state.checkedSplitTotalCents == 1_234)
        #expect(state.pendingMismatch == nil)
    }

    @Test func splitValidationDetectsOverflowWithoutTrapping() {
        var state = TransactionEditorCategoryState(
            splitRows: [
                Self.row(id: "first", amount: String(Int.max)),
                Self.row(id: "second", amount: "1")
            ]
        )

        #expect(state.validate(transactionTotal: 1, submitsAsTransfer: false) == .overflow)
    }

    @Test func autoDistributionReportsOverflowWithoutTrapping() {
        var state = TransactionEditorCategoryState(
            splitRows: [
                Self.row(id: "first", amount: String(Int.max)),
                Self.row(id: "second", amount: "1")
            ]
        )

        #expect(throws: TransactionSplitEditorError.amountOverflow) {
            try state.autoDistributeMismatch(transactionTotal: 1)
        }
        #expect(state.splitRemainingCents(transactionTotal: 1) == 0)
    }

    @Test func splitDraftsPreserveChildIdentityAndApplySign() {
        let state = TransactionEditorCategoryState(
            splitRows: [
                Self.row(id: "first", transactionID: "child-1", amount: "500"),
                Self.row(id: "second", transactionID: "child-2", amount: "734")
            ]
        )

        let drafts = state.splitDrafts(sign: -1)

        #expect(drafts.map(\.id) == ["child-1", "child-2"])
        #expect(drafts.map(\.amountMinorUnits) == [-500, -734])
    }

    @Test func loadedCategoryNamesResolveForSingleAndSplitSelections() {
        var single = TransactionEditorCategoryState(categoryID: "services", fallbackName: "services")
        var split = TransactionEditorCategoryState(
            splitRows: [
                Self.row(id: "services", amount: "500"),
                Self.row(id: "phone", amount: "734")
            ]
        )

        let names = ["services": "Services", "phone": "Phone"]
        single.resolveNames(names)
        split.resolveNames(names)

        #expect(single.selectedCategoryFallbackName == "Services")
        #expect(split.summaryName == "Services, Phone")
    }

    private static func splitState(firstAmount: String, secondAmount: String) -> TransactionEditorCategoryState {
        TransactionEditorCategoryState(
            splitRows: [
                Self.row(id: "services", name: "Services", amount: firstAmount),
                Self.row(id: "phone", name: "Phone", amount: secondAmount)
            ]
        )
    }

    private static func row(
        id: String,
        name: String? = nil,
        transactionID: String? = nil,
        amount: String
    ) -> TransactionSplitEditorRow {
        TransactionSplitEditorRow(
            id: id,
            transactionID: transactionID,
            categoryID: id,
            categoryName: name ?? id,
            amountDigits: amount
        )
    }
}
