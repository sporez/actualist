import Foundation
import Testing
@testable import Actualist

struct TransactionRowSemanticsTests {
    @Test func everyParentIsSplitRegardlessOfChildCount() {
        for childCount in [0, 1, 2, 3] {
            let children = (0..<childCount).map { index in
                transaction(
                    id: "c\(index)",
                    amount: -10,
                    category: "groceries",
                    isChild: true,
                    parentID: "parent"
                )
            }
            let parent = transaction(
                id: "parent",
                amount: -10 * childCount,
                category: nil,
                isParent: true,
                children: children,
                error: childCount == 0 ? SplitTransactionError(difference: -10) : nil
            )

            let semantics = TransactionRowSemantics.project(parent, lookup: lookup)
            #expect(semantics.isParent)
            #expect(semantics.categoryText == "Split")
            #expect(semantics.isSplitFamily)
        }
    }

    @Test func intentionalNoPayeeDiffersFromUnresolvedPayee() {
        let noPayee = TransactionRowSemantics.project(
            transaction(id: "none", payee: nil, payeeName: nil),
            lookup: lookup
        )
        let unresolved = TransactionRowSemantics.project(
            transaction(id: "missing", payee: "gone", payeeName: nil),
            lookup: lookup
        )

        #expect(noPayee.payeeKind == .noPayee)
        #expect(noPayee.payeeText == "(No payee)")
        #expect(unresolved.payeeKind == .unresolved)
        #expect(unresolved.payeeText == "Unknown Payee")
    }

    @Test func splitParentPayeeComesFromChildrenNotImportedSource() {
        let parent = transaction(
            id: "parent",
            payee: nil,
            payeeName: nil,
            importedPayee: "imported-source",
            isParent: true,
            children: [
                transaction(id: "a", payee: "store", payeeName: "Corner Store", amount: -40, isChild: true, parentID: "parent"),
                transaction(id: "b", payee: "store", payeeName: "Corner Store", amount: -60, isChild: true, parentID: "parent")
            ]
        )

        let semantics = TransactionRowSemantics.project(parent, lookup: lookup)
        #expect(semantics.payeeKind == .named)
        #expect(semantics.payeeText == "Corner Store")
        #expect(!semantics.payeeText.contains("imported"))
    }

    @Test func splitParentWithNoChildPayeesUsesSplitNoPayee() {
        let parent = transaction(
            id: "parent",
            payee: nil,
            importedPayee: "imported-source",
            isParent: true,
            children: [
                transaction(id: "a", payee: nil, amount: -40, isChild: true, parentID: "parent"),
                transaction(id: "b", payee: nil, amount: -60, isChild: true, parentID: "parent")
            ]
        )

        let semantics = TransactionRowSemantics.project(parent, lookup: lookup)
        #expect(semantics.payeeKind == .splitNoPayee)
        #expect(semantics.payeeText == "Split (no payee)")
    }

    @Test func reconciledIsDistinctFromCleared() {
        let reconciled = TransactionRowSemantics.project(
            transaction(id: "locked", cleared: true, reconciled: true),
            lookup: lookup
        )
        let cleared = TransactionRowSemantics.project(
            transaction(id: "cleared", cleared: true, reconciled: false),
            lookup: lookup
        )
        let uncleared = TransactionRowSemantics.project(
            transaction(id: "open", cleared: false, reconciled: false),
            lookup: lookup
        )

        #expect(reconciled.status == .reconciled)
        #expect(cleared.status == .cleared)
        #expect(uncleared.status == .uncleared)
    }

    @Test func notesErrorAndTransferDirectionAreProjected() {
        let transfer = TransactionRowSemantics.project(
            transaction(
                id: "xfer",
                payee: "transfer-savings",
                amount: -6000,
                notes: "moving money"
            ),
            lookup: lookup
        )
        let mismatched = TransactionRowSemantics.project(
            transaction(
                id: "parent",
                amount: -100,
                isParent: true,
                children: [
                    transaction(id: "a", amount: -40, isChild: true, parentID: "parent"),
                    transaction(id: "b", amount: -50, isChild: true, parentID: "parent")
                ],
                error: SplitTransactionError(difference: -10)
            ),
            lookup: lookup
        )

        #expect(transfer.transferDirection == .outflow)
        #expect(transfer.notes == "moving money")
        #expect(mismatched.errorDifference == -10)
        #expect(mismatched.categoryText == "Split")
    }

    @Test func privacyScramblesNamedTextButKeepsStructuralState() {
        let parent = transaction(
            id: "parent",
            payee: "store",
            payeeName: "Corner Store",
            notes: "secret",
            reconciled: true,
            isParent: true,
            children: [
                transaction(id: "a", payee: "store", payeeName: "Corner Store", amount: -40, isChild: true, parentID: "parent")
            ],
            error: SplitTransactionError(difference: 10)
        )

        let semantics = TransactionRowSemantics.project(parent, lookup: lookup, privacyEnabled: true)
        #expect(semantics.payeeKind == .named)
        #expect(semantics.payeeText != "Corner Store")
        #expect(semantics.categoryText == "Split")
        #expect(semantics.status == .reconciled)
        #expect(semantics.errorDifference == 10)
        #expect(semantics.notes != "secret")
        #expect(semantics.notes != nil)
        #expect(semantics.isParent)
    }

    private var lookup: TransactionRowLookup {
        TransactionRowLookup(
            payeeNames: ["store": "Corner Store", "transfer-savings": "Savings"],
            categoryNames: ["groceries": "Groceries"],
            transferPayeeIDs: ["transfer-savings"],
            transferAccountIDsByPayeeID: ["transfer-savings": "savings"],
            offBudgetAccountIDs: ["tracking"]
        )
    }

    private func transaction(
        id: String,
        payee: String? = "store",
        payeeName: String? = "Corner Store",
        importedPayee: String? = nil,
        amount: Int = -100,
        category: String? = "groceries",
        notes: String? = nil,
        cleared: Bool = false,
        reconciled: Bool = false,
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil,
        children: [ActualTransaction] = [],
        error: SplitTransactionError? = nil
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
            date: "2026-08-05",
            amount: amount,
            payee: payee,
            payeeName: payeeName,
            importedPayee: importedPayee,
            category: category,
            notes: notes,
            cleared: .bool(cleared),
            reconciled: reconciled,
            subtransactions: children,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            error: error
        )
    }
}
