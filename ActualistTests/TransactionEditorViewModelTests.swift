import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionEditorViewModelTests {
    @Test func formatsTypedDigitsAsCents() {
        let model = TransactionEditorViewModel()

        model.setAmountInput("500")
        #expect(model.amountCents == 500)
        #expect(model.formattedAmount.contains("5.00"))

        model.setAmountInput("50000")
        #expect(model.amountCents == 50000)
        #expect(model.formattedAmount.contains("500.00"))
    }

    @Test func filtersPayeesAndAllowsCustomName() {
        let model = TransactionEditorViewModel()
        model.payees = [
            ActualPayee(id: "amazon", name: "Amazon", category: nil, transferAccount: nil),
            ActualPayee(id: "target", name: "Target", category: nil, transferAccount: nil)
        ]

        #expect(model.filteredPayees(matching: "ama").map(\.name) == ["Amazon"])

        model.useCustomPayee("Local Coffee")
        #expect(model.payeeName == "Local Coffee")
        #expect(model.selectedPayeeID == nil)
    }
}
