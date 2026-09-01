import Foundation
import Testing
@testable import Actualist

struct SplitRemainingPresentationTests {
    @Test func expenseRemainderShowsLeftNotOver() {
        let displayed = SplitRemainingPresentation.displayedCents(remaining: -1_000, parentSignedAmount: -10_000)
        #expect(displayed == 1_000)
        #expect(
            SplitRemainingPresentation.statusText(
                remaining: -1_000,
                parentSignedAmount: -10_000,
                currency: .usd
            ) == "\(BudgetCurrency.usd.formatted(1_000)) left"
        )
    }

    @Test func expenseOverflowShowsOver() {
        #expect(SplitRemainingPresentation.displayedCents(remaining: 1_000, parentSignedAmount: -10_000) == -1_000)
        #expect(
            SplitRemainingPresentation.statusText(
                remaining: 1_000,
                parentSignedAmount: -10_000,
                currency: .usd
            ) == "\(BudgetCurrency.usd.formatted(1_000)) over"
        )
    }

    @Test func incomeRemainderShowsLeft() {
        #expect(SplitRemainingPresentation.displayedCents(remaining: 1_000, parentSignedAmount: 10_000) == 1_000)
        #expect(
            SplitRemainingPresentation.statusText(
                remaining: 1_000,
                parentSignedAmount: 10_000,
                currency: .usd
            ) == "\(BudgetCurrency.usd.formatted(1_000)) left"
        )
    }

    @Test func incomeOverflowShowsOver() {
        #expect(SplitRemainingPresentation.displayedCents(remaining: -1_000, parentSignedAmount: 10_000) == -1_000)
        #expect(
            SplitRemainingPresentation.statusText(
                remaining: -1_000,
                parentSignedAmount: 10_000,
                currency: .usd
            ) == "\(BudgetCurrency.usd.formatted(1_000)) over"
        )
    }

    @Test func balancedFamilyShowsRemaining() {
        #expect(
            SplitRemainingPresentation.statusText(
                remaining: 0,
                parentSignedAmount: -8_000,
                currency: .usd
            ) == "\(BudgetCurrency.usd.formatted(0)) Remaining"
        )
    }

    @Test func editorAndFeedShareExpenseRemainderCopy() {
        var state = TransactionSplitEditorState()
        state.replaceChildren([
            TransactionSplitEditorRow(
                id: "a",
                transactionID: "c1",
                amountMinorUnits: -4_000,
                categoryID: nil,
                categoryName: nil,
                payeeID: nil,
                payeeName: nil,
                notes: nil,
                isTransfer: false
            ),
            TransactionSplitEditorRow(
                id: "b",
                transactionID: "c2",
                amountMinorUnits: -5_000,
                categoryID: nil,
                categoryName: nil,
                payeeID: nil,
                payeeName: nil,
                notes: nil,
                isTransfer: false
            )
        ])
        #expect(state.remainingCents(parentSignedAmount: -10_000) == -1_000)
        #expect(
            state.remainingStatusText(parentSignedAmount: -10_000, currency: .usd)
                == SplitRemainingPresentation.statusText(
                    remaining: -1_000,
                    parentSignedAmount: -10_000,
                    currency: .usd
                )
        )
    }
}
