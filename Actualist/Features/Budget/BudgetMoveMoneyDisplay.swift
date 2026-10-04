import Foundation

/// Move Money labels and amounts, with the sample-values privacy mode applied.
/// Seeds are stable per draft/row so a re-render shows the same sample figure.
struct BudgetMoveMoneyDisplay {
    let isPrivacyModeEnabled: Bool
    let currency: BudgetCurrency

    func focusedCategoryName(_ draft: BudgetMoveMoneyDraft) -> String {
        guard isPrivacyModeEnabled else {
            return draft.focusedCategoryName.actualistCategoryNameParts.name
        }
        return PrivacyDisplay.name(for: .category, seed: draft.focusedCategoryID)
    }

    func headerAmountText(_ draft: BudgetMoveMoneyDraft, amount: Int) -> String {
        money(amount, seed: "move-header-\(draft.focusedCategoryID)")
    }

    func amountText(_ draft: BudgetMoveMoneyDraft, amount: Int) -> String {
        money(amount, seed: "move-display-\(draft.focusedCategoryID)-\(amount)")
    }

    func counterpartyAvailableText(_ draft: BudgetMoveMoneyDraft, amount: Int) -> String {
        money(amount, seed: "move-counterparty-\(draft.focusedCategoryID)")
    }

    func destinationTitle(for draft: BudgetMoveMoneyDraft) -> String {
        if !draft.allocations.isEmpty {
            return draft.allocations.count == 1 ? allocationTitle(draft.allocations[0]) : "Selected Categories"
        }
        guard let destination = draft.destination else {
            return "Select Category"
        }
        return destinationTitle(destination)
    }

    func allocationTitle(_ allocation: BudgetMoveMoneyAllocation) -> String {
        guard isPrivacyModeEnabled else {
            return allocation.destination.title
        }
        return destinationTitle(allocation.destination)
    }

    func allocationAmountText(_ allocation: BudgetMoveMoneyAllocation) -> String {
        money(allocation.amount, seed: "move-allocation-\(allocation.id)-\(allocation.amount)")
    }

    func groupName(_ group: BudgetMoveMoneyDestinationGroup) -> String {
        guard isPrivacyModeEnabled else {
            return group.name
        }
        return PrivacyDisplay.name(for: .categoryGroup, seed: group.id)
    }

    func optionTitle(_ option: BudgetMoveMoneyDestinationOption) -> String {
        guard isPrivacyModeEnabled else {
            return option.title
        }
        return destinationTitle(option.destination)
    }

    func optionValueText(_ option: BudgetMoveMoneyDestinationOption) -> String {
        guard isPrivacyModeEnabled else {
            return option.valueText
        }
        return money(option.amount, seed: "move-option-\(option.id)")
    }

    private func destinationTitle(_ destination: BudgetMoveMoneyDestination) -> String {
        guard isPrivacyModeEnabled else {
            return destination.title
        }
        switch destination {
        case .toBudget:
            return "To Budget"
        case .category(let id, _):
            return PrivacyDisplay.name(for: .category, seed: id)
        }
    }

    private func money(_ amount: Int, seed: String) -> String {
        guard isPrivacyModeEnabled else {
            return currency.formatted(amount)
        }
        return PrivacyDisplay.money(amount, seed: seed, currency: currency, maximumDollars: 900)
    }
}
