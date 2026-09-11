import Testing
@testable import Actualist

struct BudgetSecondValuePresentationTests {
    @Test func sharedRowsSelectLabelsAndExistingAmounts() {
        let envelope = BudgetModePresentation()
        let expense = BudgetModePresentation(isTracking: true)
        let income = BudgetModePresentation(isTracking: true, isIncome: true)
        #expect(envelope.budgetedLabel == "Assigned")
        #expect(expense.budgetedLabel == "Budgeted")
        #expect(income.budgetedLabel == "Budgeted")
        for (semantics, label, amount) in [(envelope, "Available", -123), (expense, "Balance", -123), (income, "Received", 456)] {
            let value = semantics.secondValue(balance: -123, activity: 456, carryover: true, currency: .usd)
            #expect(value.label == label)
            #expect(value.text == BudgetCurrency.usd.formatted(amount))
            #expect(value.carryover == !semantics.isIncome)
            #expect(value.accessibilityText.contains(label))
        }
        #expect(expense.activityAmount(-456) == 456)
        #expect(income.activityAmount(456) == 456)
        #expect(!income.showsBalance)
    }

    @Test func secondValueToneFormattingAndRolloverFollowDisplayedValue() {
        for currency in [BudgetCurrency.usd, .none, BudgetCurrency(code: "JPY", decimalPlaces: 0, hideFraction: false)] {
            for semantics in [BudgetModePresentation(), .init(isTracking: true), .init(isTracking: true, isIncome: true)] {
                for amount in [-1_234_567, 0, 1_234_567] {
                    let income = semantics.isIncome
                    let value = semantics.secondValue(balance: income ? -42 : amount,
                        activity: income ? amount : 42, carryover: true, currency: currency)
                    #expect(value.text == currency.formatted(amount))
                    #expect(value.tone == (amount < 0 ? .negative : amount == 0 ? .zero : .positive))
                    #expect(value.accessibilityText.contains("rollover enabled") == !income)
                }
            }
        }
    }

    @MainActor @Test func privateGridGroupAndCategoryUseProjectedSecondValues() throws {
        let snapshot = TrackingBudgetPresentationTests.loaded(try TrackingBudgetPresentationTests.month())
        let grid = BudgetGridPresentation(visibleMonths: [snapshot.month.month], snapshots: [snapshot.month.month: snapshot],
            privacyEnabled: true, showHidden: false, showTotalAssigned: false, includeCarryover: false)
        let month = grid.months[0]
        let semantics = BudgetModePresentation(isTracking: true, isIncome: true)
        let category = try #require(grid.category("salary", month: month))
        let group = try #require(grid.group("income", month: month))
        let value = semantics.secondValue(balance: category.balance, activity: category.spent, currency: month.currency)
        let total = semantics.secondValue(balance: group.balance, activity: group.spent, currency: month.currency)
        #expect(value.text == total.text)
        #expect(value.text == month.currency.formatted(category.spent))
        #expect(value.text != month.currency.formatted(snapshot.month.categoryGroups[0].spent))
        #expect(value.accessibilityText.contains(month.currency.formatted(category.spent)))
    }
}
